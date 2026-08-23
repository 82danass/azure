# v34 — Compute och kom igång

**Daniel Assarélius** · MOV25 · Microsoft Azure · Novatrix AB

Repo: [github.com/82danass/azure](https://github.com/82danass/azure) · Vecka: [v34](https://github.com/82danass/azure/tree/master/v34)

- [x] Sätt upp kursrepo på GitHub (README med namn, kurs, veckorubrik)
- [x] Provisionera Ubuntu-VM
- [x] Installera Nginx
- [x] Driftsätt kundtjänstsidan med ärendeformulär
- [x] Verifiera och dokumentera

## Verifiering

Ansluter till servern via SSH:

`ssh -i D:\MOV25\GitHub\azure\keys\vm-novatrix-web-key.pem azureuser-web@57.174.232.138`

```shell
Welcome to Ubuntu 24.04.4 LTS (GNU/Linux 6.17.0-1022-azure x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/pro

 System information as of Thu Aug 20 15:43:05 UTC 2026

  System load:  0.0               Processes:             123
  Usage of /:   6.6% of 28.02GB   Users logged in:       0
  Memory usage: 36%               IPv4 address for eth0: 172.16.0.4
  Swap usage:   0%

Last login: Thu Aug 20 15:40:29 2026 from 80.217.168.6
```

Kontrollerar att Nginx lyssnar på port 80:

`sudo ss -tulpn | grep :80`

```shell
tcp   LISTEN 0      511            0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=7566,fd=5),("nginx",pid=7565,fd=5),("nginx",pid=7564,fd=5))
tcp   LISTEN 0      511               [::]:80           [::]:*    users:(("nginx",pid=7566,fd=6),("nginx",pid=7565,fd=6),("nginx",pid=7564,fd=6))
```

Visar vilken process som äger porten:

`sudo lsof -i :80`

```shell
COMMAND  PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
nginx   7564     root    5u  IPv4  29698      0t0  TCP *:http (LISTEN)
nginx   7564     root    6u  IPv6  29699      0t0  TCP *:http (LISTEN)
nginx   7565 www-data    5u  IPv4  29698      0t0  TCP *:http (LISTEN)
nginx   7565 www-data    6u  IPv6  29699      0t0  TCP *:http (LISTEN)
nginx   7566 www-data    5u  IPv4  29698      0t0  TCP *:http (LISTEN)
nginx   7566 www-data    6u  IPv6  29699      0t0  TCP *:http (LISTEN)
```

Verifierar att webbservern svarar lokalt:

`curl -I http://127.0.0.1`

```shell
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Date: Thu, 20 Aug 2026 15:43:29 GMT
Content-Type: text/html
Content-Length: 615
Last-Modified: Thu, 20 Aug 2026 15:33:04 GMT
Connection: keep-alive
ETag: "6a871e30-267"
Accept-Ranges: bytes
```

![Nginx-standardsidan nåbar via webbläsaren](img/nginx.png)

Verifierar att porten är nåbar:

`nc -zv 127.0.0.1 80`

```shell
Connection to 127.0.0.1 80 port [tcp/http] succeeded!
```

Kopierar kundtjänstsidan (HTML/CSS) till servern och flyttar den till webbroten:

`scp -i D:\MOV25\GitHub\azure\keys\vm-novatrix-web-key.pem -r D:\MOV25\GitHub\azure\v34\public\* azureuser-web@57.174.232.138:~/ ; ssh -i D:\MOV25\GitHub\azure\keys\vm-novatrix-web-key.pem azureuser-web@57.174.232.138 "sudo mv ~/index.html ~/style.css /var/www/html/"`

```shell
index.html   100% 1091    34.4KB/s   00:00
style.css    100% 1319    39.0KB/s   00:00
```

![Novatrix kundtjänstsida med ärendeformulär](img/185024.png)

## Automatisering

Miljön är ombyggd i omgångar och många gånger, både på det sättet och från kod som IaC.
Verktygen ersätter jag med ett eget 'harness' där miljön byggs utifrån en
profil: **vad** som ska byggas blir skalbart och dynamiskt, och **hur** det ska
gå till sköts metodiskt av den underliggande infrastrukturen. Det är i ett
nötskal [Arelius-D/MOV-CLI](https://github.com/Arelius-D/MOV-CLI).

> Dokumentationen ligger öppet på [mov-cli.duckdns.org](https://mov-cli.duckdns.org). Du har dessutom bjudits in till det privata repot. Det går att installera utan att klona repot, mer om det och annat finns där.

### Profil för att driva automationen

```json
{
  "env": "v34",
  "description": "Compute: Ubuntu VM running Nginx, serving the Novatrix errand form.",

  "stages": ["preflight", "rg", "network", "cost", "compute", "verify"],

  "network": {
    "addressSpace": "10.34.0.0/16",
    "subnets": [
      { "purpose": "web", "prefix": "10.34.1.0/24", "nsg": "web" }
    ],
    "nsg": {
      "web": [
        { "name": "http", "priority": 100, "ports": ["80"] },
        { "name": "https", "priority": 110, "ports": ["443"] },
        { "name": "ssh", "priority": 120, "ports": ["22"], "source": "${admin.sshSource}" }
      ]
    }
  },

  "compute": {
    "vms": [
      { "purpose": "web", "subnet": "web" }
    ]
  }
}
```

Profilen är allt som är eget för v34. Region, taggar, budget, VM-storlek, image,
SSH-nycklar och vilket repo som klonas till värden står i
[`defaults.json`](../mov-workspace/defaults.json), namnmönstren i
[`naming.json`](../mov-workspace/naming.json). Inga Azure-värden finns i kod.

### Bygga miljön

`mov up v34`

```shell
up v34 -> rg-novatrix-v34 in swedencentral

1/6 preflight Verify tooling, identity and providers
     OK   python: 3.14
     OK   az: on PATH
     OK   ssh-keygen: on PATH
     OK   ssh: on PATH
     OK   git: on PATH
     OK   gh: Logged in to github.com account Arelius-D (keyring)
     OK   signed in as: 82danass@gafe.molndal.se
     OK   tenant: 183c226e-1463-4978-8672-ac9c4a38d90b
     OK   subscription: MOV25 - Azure subscription (Enabled)
     OK   spending limit: On (FreeTrial_2014-09-01)
     OK   resource providers: 4 registered
     OK   location: swedencentral
     OK   vm size Standard_B2ts_v2: available in swedencentral
     WARN admin exposure: web/ssh allow SSH from anywhere -- set admin.sshSource to your own address
2/6 rg Create the resource group
3/6 network Virtual network, subnets and NSGs
     mov-v34-network-e4d736b1
4/6 cost Budget and spend alerts
     mov-v34-cost-6352efcb
5/6 compute Public IP, NIC and the VM
OK   generated SSH key D:\MOV25\GitHub\azure\mov-workspace\keys\mov-v34
     mov-v34-compute-web-081ef0f0
6/6 verify Prove the deployment answers
OK   web: http://20.240.254.36/ -> 200 in 47s
```

Sista stagen gör samma kontroll mot den publika adressen som gjordes för hand
ovan, och preflight varnar för att SSH står öppet mot hela internet innan något
byggs, dock är användaren den enda med rätta nyckeln och server med ändå låset så det är ingen större fara ändå (knappast hardening men men vi är inte där än så).

### Läsa tillbaka vad som står uppe

`mov status v34`

```shell
v34 rg-novatrix-v34 present
 stage     ┃ status    ┃ when                      ┃ deployments
━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 preflight │ succeeded │ 2026-08-22T19:31:15+00:00 │
 rg        │ succeeded │ 2026-08-22T19:31:21+00:00 │
 network   │ succeeded │ 2026-08-22T19:31:59+00:00 │ mov-v34-network-e4d736b1
 cost      │ succeeded │ 2026-08-22T19:32:36+00:00 │ mov-v34-cost-6352efcb
 compute   │ succeeded │ 2026-08-22T19:33:45+00:00 │ mov-v34-compute-web-081ef0f0
 verify    │ succeeded │ 2026-08-22T19:34:31+00:00 │
  vm-novatrix-web: VM running
  6 resource(s) in the group
```

### Riva miljön när jag är klar

`mov down v34`

```shell
About to delete rg-novatrix-v34 and its 6 resource(s):
  Microsoft.Network/networkSecurityGroups  nsg-novatrix-web
  Microsoft.Network/virtualNetworks  vnet-novatrix
  Microsoft.Network/publicIPAddresses  pip-novatrix-web
  Microsoft.Network/networkInterfaces  nic-novatrix-web
  Microsoft.Compute/virtualMachines  vm-novatrix-web
  Microsoft.Compute/disks  vm-novatrix-web_OsDisk_1_d76b053332b04c7e9f8a090c8f53fbf1
  Microsoft.Consumption/budgets  budget-novatrix-v34
Delete rg-novatrix-v34? [y/N]: y
OK   deleted budget budget-novatrix-v34
OK   removed ssh entry v34-web
OK   removed key mov-v34
OK   removed key mov-v34.pub
OK   deleting rg-novatrix-v34
```

### Hur sidan hamnar på servern

Ingen fil laddas upp till servern. cloud-init klonar repot på värden och kör
[`scripts/bootstrap.sh`](../scripts/bootstrap.sh), som lägger
[`v34/public/`](public/) i webbroten och konfigurerar Nginx. Nästa `mov up` kör
om samma skript, och så når en ändring servern.

### Dokumentation och mallar

Varje kommando spelas in med sitt utdata medan deployen sker, och mallarna Azure
får är vanliga ARM-mallar:

```powershell
mov docs v34
mov templates export v34
```

`mov docs v34` skriver ut de tio kommandon som byggde miljön med sina svar.
Utskriften innehåller tenant- och subscription-id och ligger därför inte i repot.
