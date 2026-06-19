[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [string]$DbHost,

  [Parameter(Mandatory = $false)]
  [string]$SshUser = "labadmin",

  [Parameter(Mandatory = $false)]
  [string]$SshKeyPath = "$HOME\.ssh\id_rsa"
)

$remoteScript = @'
set -eu

sudo sed -i "s/^max_connections =.*/max_connections = '20'/" /etc/postgresql/14/main/postgresql.conf || true
if ! grep -q "^listen_addresses = '\*'" /etc/postgresql/14/main/postgresql.conf; then
  echo "listen_addresses = '*'" | sudo tee -a /etc/postgresql/14/main/postgresql.conf >/dev/null
fi

if ! sudo grep -q "^host[[:space:]]\+labdb[[:space:]]\+labuser[[:space:]]\+10.0.1.0/24[[:space:]]\+md5" /etc/postgresql/14/main/pg_hba.conf; then
  echo "host labdb labuser 10.0.1.0/24 md5" | sudo tee -a /etc/postgresql/14/main/pg_hba.conf >/dev/null
fi

sudo systemctl restart postgresql
sudo systemctl is-active --quiet postgresql
sudo -u postgres psql -tAc "SELECT 1;"
'@

Write-Host "Restore script prepared for $DbHost"
if ($PSCmdlet.ShouldProcess($DbHost, "Restore PostgreSQL service configuration")) {
  ssh -i $SshKeyPath "$SshUser@$DbHost" $remoteScript
}
