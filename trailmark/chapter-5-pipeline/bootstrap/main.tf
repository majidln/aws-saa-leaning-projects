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

    # Only a workflow running on main. Any other branch, tag, or pull request
    # produces a different `sub` and AWS refuses the assume-role outright.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
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

data "aws_iam_policy_document" "plan_access" {
  statement {
    sid    = "ReadDemoBucket"
    effect = "Allow"

    actions = [
      "s3:Get*",
      "s3:List*",
    ]

    resources = [
      "arn:aws:s3:::${var.stack_bucket}",
      "arn:aws:s3:::${var.stack_bucket}/*",
    ]
  }

  statement {
    sid    = "ReadOwnState"
    effect = "Allow"

    actions = ["s3:GetObject"]

    resources = [
      "arn:aws:s3:::${var.state_bucket}/chapter-5-pipeline/stack/terraform.tfstate",
    ]
  }

  statement {
    sid    = "ManageOwnLock"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "arn:aws:s3:::${var.state_bucket}/chapter-5-pipeline/stack/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid    = "ListStateBucket"
    effect = "Allow"

    actions = ["s3:ListBucket"]

    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_role_policy" "plan_access" {
  name   = "${var.prefix}-plan-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_access.json
}

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
