# miniEX mExView for iPhone

Aktuální vydání: **0.9.1 (build 2)**.

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
2. Otevřete **Actions → Build iOS → Run workflow** (workflow se nespouští automaticky).
3. Zvolte `Release` nebo `Debug` a spusťte workflow.
4. Po dokončení stáhněte artefakt `miniEXView-v0.9.1-build2-iPhone-unsigned-Release`.

Workflow se spouští pouze ručně. Používá GitHub runner `macos-15`, Xcode 16.4 a
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
