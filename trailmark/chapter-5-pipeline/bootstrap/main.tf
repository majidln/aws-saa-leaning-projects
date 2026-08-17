resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]
}

data "aws_iam_policy_document" "assume_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any pull request in this repo. Pull requests carry unreviewed code, which
    # is why this role must never be given write permissions.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "assume_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:${var.github_environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.prefix}-plan"
  description        = "Read-only role assumed by pull request workflows"
  assume_role_policy = data.aws_iam_policy_document.assume_plan.json

  tags = {
    Name = "${var.prefix}-plan"
  }
}

resource "aws_iam_role" "apply" {
  name               = "${var.prefix}-apply"
  description        = "Write role assumed only by workflows on main"
  assume_role_policy = data.aws_iam_policy_document.assume_apply.json

  tags = {
    Name = "${var.prefix}-apply"
  }
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# `terraform plan` is not purely read-only: with use_lockfile = true it writes a
# lock object to S3 and deletes it afterwards.
data "aws_iam_policy_document" "s3_access" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "s3_access" {
  name   = "${var.prefix}-s3-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.s3_access.json
}


# is one empty demo bucket.
data "aws_iam_policy_document" "apply_access" {
  statement {
    sid    = "ManageDemoBucket"
    effect = "Allow"

    actions = ["s3:*"]

    resources = [
      "arn:aws:s3:::${var.stack_bucket}",
      "arn:aws:s3:::${var.stack_bucket}/*",
    ]
  }
  statement {
    sid    = "ManageOwnState"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "arn:aws:s3:::${var.state_bucket}/chapter-5-pipeline/stack/*",
    ]
  }

  # terraform init needs to list the bucket to find the state object.
  statement {
    sid    = "ListStateBucket"
    effect = "Allow"

    actions = ["s3:ListBucket"]

    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_role_policy" "apply_access" {
  name   = "${var.prefix}-apply-access"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_access.json
}
