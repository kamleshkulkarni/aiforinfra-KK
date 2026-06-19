# Phase 2 DBA Prompts

## Diagnosis
Act as an AIOps assistant for my Azure tower. Diagnose a DBA incident where the PostgreSQL database on the DB VM is experiencing slow queries and intermittent connection failures. Use the available Terraform topology, VM/cloud-init setup, and any logs or metrics I provide. Identify the most likely root cause, separate symptoms from causes, and give a short incident summary plus immediate remediation steps.

## Automation
Act as an infrastructure automation assistant. Given a DBA incident on the PostgreSQL VM in my Azure tower, propose an automated recovery workflow using Terraform, shell, or cloud-init-compatible steps. Focus on safe actions only: health checks, service restart, config verification, connection limit review, and alerting. Do not make destructive assumptions. Output the exact commands or scripts I should run.

## Documentation
Act as a technical writer for my Azure lab. Write a concise incident note for a DBA outage in the tower: what failed, how it was detected, the likely cause, what was changed, and the prevention plan. Keep it suitable for a lab report and include a short timeline.