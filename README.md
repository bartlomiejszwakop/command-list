# Komendy

Wtyczka paska Omarchy do własnego katalogu komend. Ikona otwiera panel: piszesz, Enter kopiuje, Shift+Enter wkleja w skupione okno.

Skrót: Super+Shift+E otwiera i zamyka panel.

Przycisk **+ Grupa** zakłada pustą grupę, na przykład „Konfigurowanie Fortineta”. Potem dodajesz do niej komendy. W panelu są też przyciski: Nowa, Kopiuj, Wklej, Edytuj, Przypnij, Zapytaj i Usuń. To samo da się zrobić z klawiatury: Enter kopiuje, Shift+Enter wkleja, Alt+N dodaje, Alt+E edytuje, Alt+P przypina, Alt+A pyta OpenCode. Prawy przycisk na ikonie kopiuje przypięte albo dodaje komendę. Kółko przewija przypięte w dymku.

Katalog leży w `~/.local/share/bszwakop.commands/catalog.json`. Adres API i token są obok, w `settings.json`, i nie wchodzą do katalogu.

Synchronizacja jest wyłączona, dopóki w ustawieniach nie ma adresu. Potem:

- Pobierz robi `GET /v1/snapshot` i pokazuje, co jest nowe, nowsze na serwerze albo w konflikcie.
- Wyślij robi `PUT /v1/snapshot` z nagłówkiem `If-Match` równym rewizji lokalnego katalogu. `409` oznacza, że serwer ma nowszy katalog.

Zdjęcie ma pola `schema`, `commands` i opcjonalnie `revision`. Komenda ma `id`, `title`, `group`, `tags`, `command`, `body`, `danger`, `pinned`, `updatedAt`.

## Instalacja z tego katalogu

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests
omarchy plugin validate "$PWD"
scripts/qml-lint
scripts/deploy-local
omarchy plugin enable bszwakop.commands --section right --after vornashev.remote-hosts
```
