output "invoke_url" {
  description = "Base URL of the stage"
  value       = aws_api_gateway_stage.this.invoke_url
}

output "hello_url" {
  description = "GET this to test Step 2"
  value       = "${aws_api_gateway_stage.this.invoke_url}/hello"
}

output "hello_function_name" {
  value = aws_lambda_function.hello.function_name
}
