resource "sendgrid_sender_verification" "this" {
  nickname   = "${var.from_name} (${var.from_email})"
  from_email = var.from_email
  from_name  = var.from_name
  reply_to   = var.reply_to != "" ? var.reply_to : var.from_email
  address    = var.company_address.address
  city       = var.company_address.city
  country    = var.company_address.country
}

resource "sendgrid_api_key" "mail_send" {
  name   = var.mail_send_key_name
  scopes = ["mail.send"]
}

resource "sendgrid_unsubscribe_group" "default" {
  name        = "Default"
  description = "Default unsubscribe group for ${var.domain} transactional emails"
  is_default  = true
}
