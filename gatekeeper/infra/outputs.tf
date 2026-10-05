output "invoke_url" {
  description = "Base URL of the stage"
  value       = aws_api_gateway_stage.this.invoke_url
}

output "hello_url" {
  description = "GET this to test Step 2"
  value       = "${aws_api_gateway_stage.this.invoke_url}/hello"
}

output "items_url" {
  description = "GET this with a token to see your tenant"
  value       = "${aws_api_gateway_stage.this.invoke_url}/items"
}

output "hello_function_name" {
  value = aws_lambda_function.hello.function_name
}
