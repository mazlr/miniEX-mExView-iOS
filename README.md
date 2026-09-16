# miniEX mExView for iPhone

Aktuální vydání: **0.9.5 (build 6)**.

### Diagnostika připojení

Po ruční instalaci otevřete záložku **Diagnostika** a připojte se znovu.
Log ukáže přesný odeslaný ASCII/HEX paket i výsledek předání TCP stacku.
„Připojeno“ znamená otevřený socket; teprve řádek `RX TCP` potvrzuje odpověď
přístroje. Pokud přístroj spojení zavře, objeví se
`Odpojeno: vzdálený přístroj uzavřel TCP (EOF)`. Chyby sítě a místní odpojení
mají vlastní hlášení. Každý přijatý TCP blok se ukládá okamžitě do souboru,
ještě před dekódováním. Přes **Diagnostika → Sdílet úplný log** odešlete soubor
například do e-mailu nebo aplikace Soubory. I po pádu aplikace ho najdete v
**Soubory → Na mém iPhonu → miniEX mExView → miniEX-logs**. Vymazání zobrazené
diagnostiky soubor nesmaže. Po každém novém spuštění vznikne nový soubor.

V **Offline demo** lze na záložce Ovládání přehrát krátký (65 rámců) nebo
dlouhý (695 rámců) skutečný záznam miniEX. Přehraje se kompletní dekodér
a vykreslování, ale bez síťového připojení.

Remote Control zapněte tlačítkem na záložce **Ovládání** až po otevření socketu;
stejné tlačítko ho zase vypne. Díky tomu lze odděleně sledovat otevření TCP,
odeslání příkazu RC, ACK a přijímání obrazových rámců. Obrazovka používá
anglické bitmapy a fonty původní Android aplikace. O aplikaci a aktuální verzi
najdete v nabídce tří teček.

Nativní přepis Android aplikace pro iOS 15+ ve SwiftUI. USB vrstva je záměrně
vynechána. Aplikace zachovává TCP/Wi-Fi komunikaci, internet bridge, packetový a
CMCore protokol, vzdálený displej, nastavení přístroje, přehled naměřených dat a
offline demo.

## Spuštění

1. Otevřete `miniEXView.xcodeproj` v Xcode 16 nebo novějším.
2. V cíli **miniEXView** nastavte vlastní Team a Bundle Identifier.
3. Vyberte iPhone se systémem iOS 15+ a spusťte projekt.
4. V aplikaci otevřete **Připojení**, zadejte IP adresu a TCP port přístroje.

Lokální síť je deklarována v `Info.plist`. Připojení používá `Network.framework`.
Transport je za protokolem `MiniEXTransport`, takže lze později doplnit BLE nebo
podporovaný síťový adaptér bez změn UI a protokolu.

## Kompilace přes GitHub Actions

1. Nahrajte obsah této složky do kořene GitHub repozitáře.
2. Po každém commitu do větve `main` se automaticky spustí sestavení `Release`.
3. Volitelně otevřete **Actions → Build iOS → Run workflow** a spusťte `Release` nebo `Debug` ručně.
4. Po úspěšném běhu stáhněte artefakt `miniEXView-v0.9.8-build9-iPhone-unsigned-Release`.

Workflow se spouští po commitu do `main` i ručně. Nejdříve ověří šest přiložených záznamů a
provede testy dekodéru na iOS simulátoru, poté sestaví IPA pro fyzický telefon.
Používá GitHub runner `macos-15`, Xcode 16.4 a
nevyžaduje žádné secrets. Výsledkem je nepodepsané IPA zkompilované pro fyzický
iPhone (arm64), nikoliv pro simulátor.

Pro sedmidenní instalaci podepište stažené IPA vlastním bezplatným Apple ID v
Sideloadly nebo AltStore/SideStore. Tyto nástroje při instalaci vytvoří bezplatný
vývojářský podpis a provisioning profile; aplikaci je obvykle nutné každých sedm
dní znovu podepsat. Bez podpisu nelze IPA na běžném iPhonu spustit.

Minimální systém je iOS 15. Aplikace tedy podporuje iPhone 6s, 6s Plus, první
iPhone SE a všechny novější modely, pokud na nich běží iOS 15 nebo novější.

## Rozsah této verze

- Wi-Fi/TCP a internet bridge s 32znakovým identifikátorem
- AlphaHex, packet framing, inkrementální dekodér a CMCore zprávy
- Remote Control obrazovka 160×128, zoom, posun a tlačítko rychlosti
- tři hlavní záložky: Remote Control, Device Settings a Data
- perzistentní síťové nastavení a volba jazyka
- offline demo bez přístroje
- TSV export stažených záznamů přes systémový Share Sheet
- žádný USB kód, entitlement ani externí ovladač

Poznámka: před nasazením proti fyzickému přístroji ověřte odpovědi všech verzí
firmwaru. Zdrojový Android projekt používá více generací délek parametrů; datové
typy a framing jsou portované, ale integraci je vhodné otestovat na každém modelu.
