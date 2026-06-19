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

sudo sed -i "s/^max_connections =.*/max_connections = '1'/" /etc/postgresql/14/main/postgresql.conf || true
if ! grep -q "^listen_addresses = '\*'" /etc/postgresql/14/main/postgresql.conf; then
  echo "listen_addresses = '*'" | sudo tee -a /etc/postgresql/14/main/postgresql.conf >/dev/null
fi

sudo systemctl restart postgresql
sudo systemctl is-active --quiet postgresql
for i in 1 2 3 4 5; do
  (sudo -u postgres psql -d labdb -c "SELECT pg_sleep(10);" >/tmp/db-fault-$i.log 2>&1 &) 
done
wait
'@

Write-Host "Fault injection script prepared for $DbHost"
if ($PSCmdlet.ShouldProcess($DbHost, "Inject PostgreSQL connection-exhaustion fault")) {
  ssh -i $SshKeyPath "$SshUser@$DbHost" $remoteScript
}
