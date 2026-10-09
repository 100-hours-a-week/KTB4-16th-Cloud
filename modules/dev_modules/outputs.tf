output "vm_public_ip" {
  value = google_compute_address.vm.address
}

output "site_url" {
  value = "https://${var.domain}"
}

output "mysql_public_ip" {
  value = google_sql_database_instance.mysql.public_ip_address
}

output "postgres_public_ip" {
  value = google_sql_database_instance.postgres.public_ip_address
}

output "image_bucket_name" {
  value = google_storage_bucket.images.name
}

output "vm_service_account" {
  value = google_service_account.vm.email
}
