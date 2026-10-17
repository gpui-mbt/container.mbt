///|
test "failure classification maps engine and xpc errors" {
  assert_true(
    classify_failure(EngineError::ImageNotFound(op="pull", image="a:1")) is
    Client(ImageNotFound),
  )
  assert_true(
    classify_failure(EngineError::ContainerNotFound(op="rm", container="x")) is
    Client(ContainerNotFound),
  )
  assert_true(
    classify_failure(
      EngineError::ContainerPathNotFound(op="copy", container="x", path="/a"),
    ) is Client(ContainerPathNotFound),
  )
  assert_true(
    classify_failure(EngineError::Unauthorized(op="pull", message="401")) is
    Client(Authentication),
  )
  assert_true(
    classify_failure(EngineError::DeadlineExceeded(op="exec")) is Client(Timeout),
  )
  assert_true(classify_failure(XpcError::Connect) is Client(Connect))
  assert_true(classify_failure(XpcError::Timeout) is Client(Timeout))
  assert_true(
    classify_failure(XpcError::Remote(code="notFound", message="container x not found")) is
    Client(ContainerNotFound),
  )
}

///|
test "failure redaction hides registry credentials" {
  let text = redact_secret(
    "Authorization: Bearer abc123 password=hunter2 token=tok_xyz",
  )
  assert_true(!text.contains("abc123"))
  assert_true(!text.contains("hunter2"))
  assert_true(!text.contains("tok_xyz"))
  assert_true(text.contains("[REDACTED]"))
}
