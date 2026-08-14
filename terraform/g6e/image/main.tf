data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "eks-gpu-node-auto-repair-codebuild-${local.account_id}-${var.region}"
}

resource "aws_ecr_repository" "train" {
  name         = var.ecr_repo_name
  force_delete = true
}

resource "aws_s3_bucket" "build_context" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_iam_role" "codebuild" {
  name = "eks-gpu-node-auto-repair-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "eks-gpu-node-auto-repair-codebuild-policy"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.build_context.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
          "ecr:BatchGetImage"
        ]
        Resource = aws_ecr_repository.train.arn
      }
    ]
  })
}

resource "aws_codebuild_project" "image_build" {
  name         = var.project_name
  service_role = aws_iam_role.codebuild.arn

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    type            = "LINUX_CONTAINER"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    privileged_mode = true
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.build_context.bucket}/build-context/src.zip"
    buildspec = "buildspec.yml"
  }
}
