locals {
  items_name = "gatekeeper-items"
}

# ---------- Lambda: items ----------

data "archive_file" "items" {
  type        = "zip"
  source_file = "${path.module}/../build/items/bootstrap"
  output_path = "${path.module}/../build/items.zip"
}

resource "aws_cloudwatch_log_group" "items" {
  name              = "/aws/lambda/${local.items_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "items" {
  function_name = local.items_name
  role          = aws_iam_role.items.arn

  filename         = data.archive_file.items.output_path
  source_code_hash = data.archive_file.items.output_base64sha256

  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"

  depends_on = [
    aws_cloudwatch_log_group.items,
    aws_iam_role_policy.items_logs,
  ]
}

# ---------- IAM: logs only ----------
# No DynamoDB yet — Step 5 adds it, scoped to the one table.

resource "aws_iam_role" "items" {
  name               = local.items_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "items_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.items.arn}:*"]
  }
}

resource "aws_iam_role_policy" "items_logs" {
  name   = "write-own-logs"
  role   = aws_iam_role.items.id
  policy = data.aws_iam_policy_document.items_logs.json
}
