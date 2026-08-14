output "ecr_repo_url" {
  value = aws_ecr_repository.train.repository_url
}

output "ecr_repo_name" {
  value = aws_ecr_repository.train.name
}

output "bucket_name" {
  value = aws_s3_bucket.build_context.bucket
}

output "project_name" {
  value = aws_codebuild_project.image_build.name
}
