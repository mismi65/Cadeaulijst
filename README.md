# Cadeaulijst (PWA)

Iedereen kan een verlanglijst maken, de link delen, en gevers strepen af wat ze gaan kopen. De jarige ziet **niet** wat er is afgestreept, zodat de verrassing blijft.

**Stack:** één `index.html` (geen build-stap) · Supabase (database) · Vercel of Cloudflare Pages (hosting).

## Hoe het werkt

| Wie | Link | Kan |
|---|---|---|
| Jarige | `…/#/b/<code>/<geheime-token>` (beheerlink) | lijst en cadeaus aanmaken, wijzigen, verwijderen; ziet géén afstrepingen |
| Gevers | `…/#/l/<code>` (deellink) | cadeaus afstrepen ("Ik koop dit"), eigen afstreping terugdraaien, zien wie wat koopt |

- Geen accounts. De beheerlink is de sleutel; die wordt ook in de browser onthouden onder "Mijn lijsten".
- Afstrepen is atomair: als twee mensen tegelijk klikken, krijgt er één "Iemand was je net voor".
- Een gever kan alleen zijn eigen afstreping ongedaan maken (gekoppeld aan zijn browser).
- Opent de jarige zelf de deellink, dan verschijnt een spoilerscherm.
- De lijst ververst elke 15 seconden.
- Alle database-toegang loopt via functies; de tabellen zelf zijn dicht (RLS), dus de anon key en beheertokens zijn veilig.

## Installeren (± 10 minuten)

### 1. Supabase
1. Maak een nieuw project op supabase.com.
2. Ga naar **SQL Editor → New query**, plak de volledige inhoud van `supabase.sql` en klik **Run**.
3. Ga naar **Project Settings → API** en kopieer de **Project URL** en de **anon public** key.

### 2. Config
Vul in `config.js`:
```js
window.CADEAULIJST_CONFIG = {
  supabaseUrl: "https://jouwproject.supabase.co",
  supabaseAnonKey: "eyJ..."
};
```
Lege config? Dan toont de app een "Bijna klaar"-scherm, er is bewust geen stille fallback naar lokale opslag.

### 3a. Vercel
Kies één van twee:
- **Via de terminal** (snelst): ga in de map staan en run `npx vercel` (eerste keer inloggen en vragen beantwoorden: geen framework, geen build command, output-map `.`). Daarna `npx vercel --prod` om live te zetten.
- **Via GitHub**: zet de map in een repo en kies in Vercel *Add New → Project → Import*. Framework preset: *Other*, geen build command. Elke push gaat dan automatisch live.

`vercel.json` regelt de cache-instellingen. Het Hobby-abonnement (gratis) is bedoeld voor persoonlijk, niet-commercieel gebruik.

### 3b. Of: Cloudflare Pages
1. **Workers & Pages → Create → Pages → Upload assets**.
2. Sleep de hele map (incl. `icons/`, `sw.js`, `manifest.webmanifest`, `_headers`) erin en deploy.
3. Open de `*.pages.dev`-URL, maak een lijst en test met een tweede browser (of privévenster) als gever.

Een eigen domein koppel je onder **Custom domains**. Een PWA vereist HTTPS; dat regelt Pages.

## Bestanden
- `index.html` – de complete app (HTML, CSS, JS)
- `config.js` – Supabase-koppeling
- `supabase.sql` – tabellen, beveiliging en functies
- `manifest.webmanifest`, `sw.js`, `icons/` – PWA (installeerbaar, app-schil offline)
- `vercel.json` (Vercel) / `_headers` (Cloudflare) – zorgen dat updates van `sw.js` en `config.js` direct doorkomen

## Updaten
Wijzig `index.html` en upload opnieuw. Verander bij grote wijzigingen `CACHE = "cadeaulijst-v1"` in `sw.js` naar `v2`, zodat telefoons de nieuwe versie direct oppakken.
