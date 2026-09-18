locals {
  hello_name = "gatekeeper-hello"
}

# ---------- Lambda: hello ----------

data "archive_file" "hello" {
  type        = "zip"
  source_file = "${path.module}/../build/hello/bootstrap"
  output_path = "${path.module}/../build/hello.zip"
}

resource "aws_cloudwatch_log_group" "hello" {
  name              = "/aws/lambda/${local.hello_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "hello" {
  function_name = local.hello_name
  role          = aws_iam_role.hello.arn

  filename         = data.archive_file.hello.output_path
  source_code_hash = data.archive_file.hello.output_base64sha256

  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"

  # Log group must exist first, or Lambda creates its own with no retention.
  depends_on = [
    aws_cloudwatch_log_group.hello,
    aws_iam_role_policy.hello_logs,
  ]
}

# ---------- IAM ----------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "hello" {
  name               = local.hello_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "hello_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.hello.arn}:*"]
  }
}

resource "aws_iam_role_policy" "hello_logs" {
  name   = "write-own-logs"
  role   = aws_iam_role.hello.id
  policy = data.aws_iam_policy_document.hello_logs.json
}
