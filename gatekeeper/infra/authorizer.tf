locals {
  authorizer_name = "gatekeeper-authorizer"
}

# ---------- Lambda: authorizer ----------

data "archive_file" "authorizer" {
  type        = "zip"
  source_file = "${path.module}/../build/authorizer/bootstrap"
  output_path = "${path.module}/../build/authorizer.zip"
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.authorizer_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "authorizer" {
  function_name = local.authorizer_name
  role          = aws_iam_role.authorizer.arn

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"

  environment {
    variables = {
      AUTH0_DOMAIN   = var.auth0_domain
      AUTH0_AUDIENCE = var.auth0_audience
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.authorizer,
    aws_iam_role_policy.authorizer_logs,
  ]
}

# ---------- IAM: logs only, nothing else ----------

resource "aws_iam_role" "authorizer" {
  name               = local.authorizer_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "authorizer_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.authorizer.arn}:*"]
  }
}

resource "aws_iam_role_policy" "authorizer_logs" {
  name   = "write-own-logs"
  role   = aws_iam_role.authorizer.id
  policy = data.aws_iam_policy_document.authorizer_logs.json
}

# ---------- API Gateway authorizer ----------

resource "aws_api_gateway_authorizer" "this" {
  name           = local.authorizer_name
  rest_api_id    = aws_api_gateway_rest_api.gatekeeper.id
  type           = "REQUEST"
  authorizer_uri = aws_lambda_function.authorizer.invoke_arn

  # Cache key. Also: a request without this header gets 401 from API Gateway
  # before the authorizer is ever invoked.
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = var.authorizer_cache_ttl
}

resource "aws_lambda_permission" "apigw_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.gatekeeper.execution_arn}/authorizers/${aws_api_gateway_authorizer.this.id}"
}
