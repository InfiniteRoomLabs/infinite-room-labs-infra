variable "domain" {
  type        = string
  description = "Domain to send email from (e.g., infiniteroomlabs.com)"
}

variable "from_email" {
  type        = string
  description = "Sender email address (e.g., no-reply@infiniteroomlabs.com)"
}

variable "from_name" {
  type        = string
  description = "Display name shown to recipients"
}

variable "reply_to" {
  type        = string
  default     = ""
  description = "Reply-to email address. Defaults to from_email if empty."
}

variable "company_address" {
  type = object({
    address = string
    city    = string
    country = string
  })
  description = "Physical address for CAN-SPAM compliance"
}

variable "mail_send_key_name" {
  type        = string
  default     = "irl-mail-send"
  description = "Name for the scoped mail-send API key"
}
