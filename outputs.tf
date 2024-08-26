output "app_url" {
  value = aws_alb.application_load_balancer.dns_name
  description = "The URL of the application load balancer"
}
