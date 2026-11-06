# VPN Access

## Requesting access

VPN access is granted per team. Your manager raises the request in the service
portal under Access Requests, selects the network zone and names the systems
you need to reach. Approval usually completes within one business day.

## Connecting

Install the corporate VPN client from the software catalogue, then sign in
with your work account. Multi factor authentication is always required, even
on a managed laptop. Split tunnelling is disabled, so all traffic flows
through the corporate gateway while the tunnel is up.

## Common connection failures

A tunnel that drops every few minutes is usually caused by an unstable
wireless connection rather than by the gateway. Switch to a wired connection
to confirm before escalating.

Error 812 means the account is not yet a member of the VPN group. Error 691
means the credentials were rejected, most often because the password was
changed recently and the client cached the old one.
