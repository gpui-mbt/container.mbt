// Copyright 2026 gpui-mbt contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
test "escape_json handles quotes, controls, and unicode escapes" {
  assert_eq(escape_json("plain"), "\"plain\"")
  assert_eq(escape_json("a\"b\\c"), "\"a\\\"b\\\\c\"")
  assert_eq(
    escape_json("line\nfeed\t\u{07}\u{01}"),
    "\"line\\nfeed\\t\\u0007\\u0001\"",
  )
  assert_eq(escape_json("caf\u{e9}"), "\"caf\u{e9}\"")
}

///|
test "create body serializes the full GenericImage surface" {
  let image = try! GenericImage::new("alpine", "3.20")
    .with_cmd(["sh", "-c", "sleep 60"])
    .with_entrypoint("/bin/sh")
    .with_env_var("KEY", "va\"l")
    .with_label("app", "demo")
    .with_working_dir("/work")
    .with_user("1000")
    .with_network("mynet")
    .with_readonly_rootfs(true)
  let req = try! create_request(image)
  inspect(
    req.to_json(),
    content=(
      #|{"Image":"alpine:3.20","Entrypoint":["/bin/sh"],"Cmd":["sh","-c","sleep 60"],"Env":["KEY=va\"l"],"Labels":{"app":"demo"},"WorkingDir":"/work","User":"1000","NetworkingConfig":{"EndpointsConfig":{"mynet":{}}},"HostConfig":{"Privileged":false,"Init":false,"ReadonlyRootfs":true}}
    ),
  )
}

///|
test "ports serialize as ExposedPorts plus PortBindings" {
  let image = try! GenericImage::new("nginx", "1.27")
    .with_mapped_port(8080, try! ContainerPort::tcp(80))
    .with_exposed_port(try! ContainerPort::udp(53))
  let req = try! create_request(image)
  inspect(
    req.to_json(),
    content=(
      #|{"Image":"nginx:1.27","ExposedPorts":{"80/tcp":{},"53/udp":{}},"HostConfig":{"Privileged":false,"Init":false,"ReadonlyRootfs":false,"PortBindings":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}],"53/udp":[{"HostIp":"0.0.0.0","HostPort":"0"}]}}}
    ),
  )
}

///|
test "mounts serialize to Binds and Mounts" {
  let image = try! GenericImage::new("alpine", "3.20")
    .with_mount(Mount::bind_mount("/h", "/c").with_read_only())
    .with_mount(Mount::volume_mount("vol", "/v"))
    .with_mount(Mount::tmpfs_mount("/run"))
  let req = try! create_request(image)
  inspect(
    req.to_json(),
    content=(
      #|{"Image":"alpine:3.20","HostConfig":{"Privileged":false,"Init":false,"ReadonlyRootfs":false,"Binds":["/h:/c:ro"],"Mounts":[{"Type":"volume","Source":"vol","Target":"/v","ReadOnly":false},{"Type":"tmpfs","Target":"/run","ReadOnly":false}]}}
    ),
  )
}

///|
test "the create request snapshot ignores later builder mutations" {
  let image = try! GenericImage::new("alpine", "3.20").with_cmd(["a"])
  let req = try! create_request(image)
  let json_before = req.to_json()
  ignore(image.with_cmd(["b"]).with_env_var("K", "V"))
  let req_after = try! create_request(image)
  assert_eq(req.to_json(), json_before)
  assert_true(req_after.to_json().contains("\"b\""))
}

///|
test "duplicate container ports fail before any socket traffic" {
  let image = try! GenericImage::new("alpine", "3.20")
    .with_mapped_port(1, try! ContainerPort::tcp(80))
    .with_mapped_port(2, try! ContainerPort::tcp(80))
  try create_request(image) catch {
    Failure(f) =>
      assert_true(f.to_string().contains("duplicate published container port"))
    err => fail("expected Failure, got \{err}")
  } noraise {
    _ => fail("expected duplicate-port rejection")
  }
}

///|
async test "create then start sends both calls with an encoded query" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        2,
        fn(head) {
          if head.contains("/start") {
            http_resp("204", "No Content", "")
          } else {
            http_200("{\"Id\":\"abc123\",\"Warnings\":[]}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let image = try! GenericImage::new("alpine", "3.20")
      .with_container_name("my-app")
      .with_platform("linux/amd64")
    let id = client.create_and_start(image)
    assert_eq(id, "abc123")
    assert_eq(requests, [
      "POST /containers/create?name=my-app&platform=linux%2Famd64 HTTP/1.1", "POST /containers/abc123/start HTTP/1.1",
    ])
  })
}

///|
async test "a start failure force-removes only the created id" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        3,
        fn(head) {
          if head.contains("/start") {
            http_resp("500", "Server Error", "{\"message\":\"boom\"}")
          } else if head.contains("DELETE") {
            http_resp("204", "No Content", "")
          } else {
            http_200("{\"Id\":\"deadbeef\"}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let image = try! GenericImage::new("alpine", "3.20")
    try client.create_and_start(image) catch {
      EngineError::ServerError(op="start container", status=500, ..) => ()
      err => fail("expected ServerError, got \{err}")
    } noraise {
      _ => fail("expected start to fail")
    }
    assert_eq(requests, [
      "POST /containers/create HTTP/1.1", "POST /containers/deadbeef/start HTTP/1.1",
      "DELETE /containers/deadbeef?force=true HTTP/1.1",
    ])
  })
}

///|
async test "a create response without Id is rejected before start" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) { http_200("{\"Warnings\":[]}") },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let image = try! GenericImage::new("alpine", "3.20")
    try client.create_and_start(image) catch {
      EngineError::MalformedResponse(op="create container", ..) => ()
      err => fail("expected MalformedResponse, got \{err}")
    } noraise {
      _ => fail("expected create to fail")
    }
    // Only the create request went out; no empty-id start was attempted.
    assert_eq(requests.length(), 1)
  })
}
