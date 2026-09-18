resource "aws_api_gateway_rest_api" "gatekeeper" {
  name = "gatekeeper"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ---------- GET /hello ----------

resource "aws_api_gateway_resource" "hello" {
  rest_api_id = aws_api_gateway_rest_api.gatekeeper.id
  parent_id   = aws_api_gateway_rest_api.gatekeeper.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "hello_get" {
  rest_api_id   = aws_api_gateway_rest_api.gatekeeper.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "hello_get" {
  rest_api_id = aws_api_gateway_rest_api.gatekeeper.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_get.http_method

  type = "AWS_PROXY"
  # How API Gateway calls Lambda — always POST, whatever the client's method.
  integration_http_method = "POST"
  uri                     = aws_lambda_function.hello.invoke_arn
}

resource "aws_lambda_permission" "apigw_hello" {
  statement_id  = "AllowAPIGatewayInvokeHello"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.gatekeeper.execution_arn}/*/GET/hello"
}

# ---------- Deployment ----------

resource "aws_api_gateway_deployment" "gatekeeper" {
  rest_api_id = aws_api_gateway_rest_api.gatekeeper.id

  # A deployment is a snapshot; any route change must produce a new one.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.hello.id,
      aws_api_gateway_method.hello_get.id,
      aws_api_gateway_integration.hello_get.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.gatekeeper.id
  deployment_id = aws_api_gateway_deployment.gatekeeper.id
  stage_name    = var.stage_name
}

# Renamed from aws_api_gateway_stage.prod when stage_name became a variable —
# without this, Terraform would see "this" as a brand-new resource and try
# to destroy "prod" and create "this" alongside the unavoidable replacement
# that changing stage_name itself already causes (AWS treats it as ForceNew).
moved {
  from = aws_api_gateway_stage.prod
  to   = aws_api_gateway_stage.this
}
