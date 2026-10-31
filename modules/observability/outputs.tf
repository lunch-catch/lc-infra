output "critical_topic_arn" {
  description = "critical 알림 SNS 주제. AWS Chatbot 이 구독한다"
  value       = aws_sns_topic.critical.arn
}
