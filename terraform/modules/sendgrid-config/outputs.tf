output "sender_id" {
  value       = sendgrid_sender_verification.this.id
  description = "Verified sender ID"
}

output "sender_verified" {
  value       = sendgrid_sender_verification.this.verified
  description = "Whether the sender identity is verified"
}

output "mail_send_api_key" {
  value       = sendgrid_api_key.mail_send.api_key
  sensitive   = true
  description = "Scoped mail-send API key for applications"
}

output "mail_send_api_key_id" {
  value       = sendgrid_api_key.mail_send.id
  description = "ID of the mail-send API key"
}

output "unsubscribe_group_id" {
  value       = sendgrid_unsubscribe_group.default.id
  description = "Default unsubscribe group ID for email sends"
}
