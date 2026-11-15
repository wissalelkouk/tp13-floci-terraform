# TP13 partie 4 : buckets via le module secure-bucket.

module "uploads" {
  source = "./modules/secure-bucket"
  name   = "tp13-uploads-${var.environment}"
}

module "backups" {
  source = "./modules/secure-bucket"
  name   = "tp13-backups-${var.environment}"
}

# Les ressources existantes changent d'adresse : Terraform les déplace
# dans le state au lieu de les détruire puis recréer.
moved {
  from = aws_s3_bucket.uploads
  to   = module.uploads.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_versioning.uploads
  to   = module.uploads.aws_s3_bucket_versioning.this
}

moved {
  from = aws_s3_bucket_public_access_block.uploads
  to   = module.uploads.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.uploads
  to   = module.uploads.aws_s3_bucket_server_side_encryption_configuration.this
}

# ---------- SQS avec file de lettres mortes ----------
resource "aws_sqs_queue" "contact_dlq" {
  name                    = "tp13-contact-dlq-${var.environment}"
  sqs_managed_sse_enabled = true
}

resource "aws_sqs_queue" "contact" {
  name                    = "tp13-contact-${var.environment}"
  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.contact_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "visits" {
  name         = "tp13-visits-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# ---------- Secrets Manager (valeur hors du code) ----------
resource "aws_secretsmanager_secret" "api_key" {
  name = "tp13/${var.environment}/api-key"
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = var.api_key
}
