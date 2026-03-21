output "record_ids" {
  value = {
    for name, record in cloudflare_dns_record.this : name => record.id
  }
  description = "Map of type-name key to Cloudflare DNS record ID"
}

output "record_hostnames" {
  value = {
    for name, record in cloudflare_dns_record.this : name => record.name
  }
  description = "Map of record key to fully qualified hostname"
}
