# Azure

**Daniel Assarélius** · MOV25 · Microsoft Azure · Novatrix AB

Repo: [github.com/82danass/azure](https://github.com/82danass/azure)

## Uppgifter

### [v34 — Compute och kom igång](v34/README.md)
- [x] Sätt upp kursrepo på GitHub (README med namn, kurs, veckorubrik)
- [x] Provisionera Ubuntu-VM
- [x] Installera Nginx
- [x] Driftsätt kundtjänstsidan med ärendeformulär
- [x] Verifiera och dokumentera

### [v35 — IAM och identitet](v35/README.md)
- [x] Uppdatera README för v35
- [x] Skapa identiteter/grupper i Entra ID
- [x] Tilldela RBAC-roller (least privilege)
- [x] Förbered managed identity för appen
- [x] Verifiera och dokumentera

### [v36 — Nätverk och säkerhet](v36/README.md)
- [x] Uppdatera README för v36
- [x] Bygg VNet med publikt/privat subnät
- [x] Säkra trafiken med NSG:er
- [x] Placera lösningen i nätverket
- [x] Verifiera och dokumentera

### [v37 — Storage](v37/README.md)
- [x] Uppdatera README för v37
- [x] Skapa storage account + Blob container
- [x] Koppla formuläret till lagringen
- [x] Säkra åtkomsten (managed identity, least privilege)
- [x] Verifiera och dokumentera

### [v38 — IaC med ARM-templates](v38/README.md)
- [x] Uppdatera README för v38
- [x] Skriv ARM-template(s) för VM, nätverk, storage
- [x] Deploya miljön från kod
- [x] Visa versionshantering (ändring + historik)
- [x] Dokumentera hur miljön återskapas

### [v39 — Automation och integration](v39/README.md)
- [x] Uppdatera README för v39
- [x] Bygg Power Automate-flöde (trigger vid nytt ärende): en ny rad i registret avfyrar dess webhook, som kör notifieraren, och notifieraren triggar Workflows-flödet i Teams
- [x] Integrera mot Microsoft 365 (SharePoint-lista, Teams/Outlook-notis): ärenderegistret i stället för SharePoint-listan, notisen som mejl genom Azure Communication Services och som kort i en Teams-kanal
- [x] Koppla flödet till Azure-lösningen: hela kedjan, från formuläret till mejlet, körs i Azure och deployas från repot
- [x] Verifiera och dokumentera hela kedjan

### [v40](v40/README.md)
- [x] Skapa avsnitt för v40 och uppdatera README
- [x] Paketera och kör en del av kundtjänsten som en container på Azure: ärendeformuläret på Azure Container Apps, med imagen byggd av GitHub Actions
- [x] Beskriv och jämför VM, containers och serverless, med för- och nackdelar för just ärendemottagningen
- [x] Visa att den alternativa lösningen fungerar och dokumentera jämförelsen: formuläret svarar på sitt eget namn över HTTPS och ett ärende med bilaga landar som en rad i ärenderegistret

### [v41](v41/README.md)
- [x] Skapa avsnitt för v41 och uppdatera README
- [x] Del A: redogör för tjänsterna inom compute, nätverk och storage, förklara virtualiseringsnivåerna och motivera nivån för portalen: container för portalen, serverless för funktionen som tar anmälningarna
- [x] Delmoment 1, Compute: värdmiljön och felanmälan med rubrik, beskrivning och bild: portalen och ekonomisidan på Azure Container Apps i en zonredundant miljö, funktionen på Flex Consumption
- [x] Delmoment 2, IAM: Nordviks roller enligt least privilege och en hanterad identitet mot lagringen: en grupp per roll bland personalen, hyresgästen utan konto med en engångskod, en hanterad identitet per uppgift
- [x] Delmoment 3, Nätverk och säkerhet: defense in depth med en publik portal och skyddad lagring: lagringen bara på privata slutpunkter bakom en nätverkssäkerhetsgrupp, nycklarna avstängda
- [x] Delmoment 4, Storage: säker lagring av bilder och dokument: blob, tabeller och kö i ett zonredundant konto utan publik adress, dokumenten till Cool efter 90 dagar
- [x] Delmoment 5, IaC: ARM-templates i GitHub, återskapbart från repot: allt i Azure från en profil med mov, tenantens del med setup.ps1
- [x] Delmoment 6, Automation och integration: en post i en lista och en notis till rätt förvaltare i Nordviks Microsoft 365: funktionen för in posten i SharePoint-listan genom Microsoft Graph och mejlar genom Communication Services
- [x] Delmoment 7, Dokumentation: hur lösningen planerats, byggts och återskapas: den här README:n
