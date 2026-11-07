# Amazon Managed Service for Prometheus.
#
# The SLO recording rules and burn-rate alerts in
# observability/alerts/rules.yml are uploaded here unchanged, so the
# objectives in docs/slo.md are evaluated in production rather than only in
# docker-compose. Argo Rollouts queries the same workspace to decide whether
# a canary may proceed, which is what connects the deployment strategy to
# the service level objectives instead of to a timer.

resource "aws_prometheus_workspace" "main" {
  alias = "${local.name_prefix}-metrics"
  tags  = var.tags
}

# The rules file is the single source of truth. It is uploaded verbatim: no
# second copy to drift, and the recording rules evaluate here, so the
# burn-rate alerts can reference them exactly as they do locally.
resource "aws_prometheus_rule_group_namespace" "slo" {
  name         = "jenie-slo"
  workspace_id = aws_prometheus_workspace.main.id
  data         = file("${path.module}/../../../observability/alerts/rules.yml")
}

resource "aws_prometheus_alert_manager_definition" "main" {
  workspace_id = aws_prometheus_workspace.main.id

  definition = yamlencode({
    alertmanager_config = yamlencode({
      route = {
        receiver = "sns"
        # Pages and tickets are routed by the label the rules already set,
        # so severity is decided in one place.
        routes = [{
          receiver = "sns"
          matchers = ["page = \"true\""]
          # A page repeats; a ticket does not need to.
          repeat_interval = "1h"
        }]
        group_by        = ["alertname", "slo"]
        group_wait      = "30s"
        repeat_interval = "12h"
      }
      receivers = [{
        name = "sns"
        sns_configs = [{
          topic_arn = aws_sns_topic.alerts.arn
          sigv4     = { region = var.region }
          subject   = "{{ .CommonLabels.alertname }}"
        }]
      }]
    })
  })
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Alertmanager publishes as the workspace, so the topic must accept it.
resource "aws_sns_topic_policy" "amp" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "aps.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnEquals    = { "aws:SourceArn" = aws_prometheus_workspace.main.arn }
      }
    }]
  })
}
