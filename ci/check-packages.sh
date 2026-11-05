#!/usr/bin/env bash
# Проверка собранных APK перед публикацией.
# Использование: ci/check-packages.sh <каталог SDK> <каталог с APK>
# Любая найденная проблема завершает скрипт с кодом 1.
set -uo pipefail

SDK=${1:?SDK dir}
OUT=${2:?APK dir}
APK="$SDK/staging_dir/host/bin/apk"
fail=0

bad() { printf 'ОШИБКА: %s\n' "$*"; fail=1; }
ok()  { printf 'OK: %s\n' "$*"; }

[ -x "$APK" ] || { echo "ОШИБКА: не найден $APK"; exit 1; }

# Что обязательно должно быть в каждом пакете (путь внутри пакета).
declare -A REQUIRED
REQUIRED[warp-awg]="usr/libexec/warp-amneziawg-go usr/libexec/warp-awgctl"
REQUIRED[warp-warpscout]="usr/libexec/warp-warpscout"
REQUIRED[luci-app-warp]="usr/libexec/warp-manager usr/libexec/warp-autotune usr/libexec/warp-test usr/libexec/warp-limit usr/libexec/warp-probe usr/libexec/warp-common usr/libexec/warp-api usr/libexec/warp-job usr/libexec/warp-podkop usr/libexec/warp-setup usr/libexec/warp-watchdog usr/libexec/warp-awg-runner usr/share/warp-test/score.awk usr/share/warp-test/services.tsv etc/init.d/warp etc/init.d/warp-watchdog etc/config/warp"

# Файлы, которые запускаются напрямую и обязаны иметь бит исполнения.
EXEC_DIRS="usr/libexec etc/init.d"

for pkg in warp-awg warp-warpscout luci-app-warp; do
  files=("$OUT/$pkg"-*.apk)
  if [ ! -e "${files[0]}" ] || [ "${#files[@]}" -ne 1 ]; then
    bad "$pkg: ожидался ровно один APK, найдено ${#files[@]}"
    continue
  fi
  f=${files[0]}
  echo "=== $(basename "$f")"

  tmp=$(mktemp -d)
  if ! "$APK" extract --allow-untrusted --no-chown --destination "$tmp" "$f" >"$tmp.log" 2>&1; then
    bad "$pkg: apk extract не удался"
    cat "$tmp.log"
    "$APK" adbdump --allow-untrusted "$f" 2>&1 | head -60
    continue
  fi

  for rel in ${REQUIRED[$pkg]}; do
    if [ -f "$tmp/$rel" ]; then ok "$pkg: есть $rel"; else bad "$pkg: нет файла $rel"; fi
  done

  for d in $EXEC_DIRS; do
    [ -d "$tmp/$d" ] || continue
    while IFS= read -r p; do
      mode=$(stat -c '%a' "$p")
      rel=${p#"$tmp"/}
      if [ "$mode" = 755 ]; then ok "режим 755: $rel"; else bad "$pkg: $rel имеет режим $mode, нужен 755"; fi
    done < <(find "$tmp/$d" -type f | sort)
  done

  # Архитектура бинарников.
  while IFS= read -r p; do
    info=$(file -b "$p")
    case "$info" in
      *ELF*x86-64*) ok "x86-64 ELF: ${p#"$tmp"/}" ;;
      *ELF*)        bad "$pkg: ${p#"$tmp"/} — не x86-64: $info" ;;
    esac
  done < <(find "$tmp/usr/libexec" -type f 2>/dev/null | sort)

  # Архитектура в метаданных пакета.
  arch=$("$APK" adbdump --allow-untrusted "$f" 2>/dev/null | awk '/^ *arch:/ {print $2; exit}')
  case "$pkg" in
    luci-app-warp) want='noarch|all' ;;
    *)             want='x86_64' ;;
  esac
  if [[ "$arch" =~ ^($want)$ ]]; then ok "$pkg: arch = $arch"; else bad "$pkg: arch = '${arch:-?}', ожидалось $want"; fi

  # kmod-tun убран из зависимостей сборки (см. workflow), но обязан остаться
  # зависимостью установки: без него на роутере не будет /dev/net/tun.
  if [ "$pkg" = warp-awg ]; then
    dump=$("$APK" adbdump --allow-untrusted "$f" 2>&1)
    if grep -q 'kmod-tun' <<<"$dump"; then
      ok "$pkg: зависимость kmod-tun есть в метаданных"
    else
      bad "$pkg: в метаданных нет зависимости kmod-tun (EXTRA_DEPENDS не сработал)"
      head -50 <<<"$dump"
    fi
  fi

  rm -rf "$tmp" "$tmp.log"
done

(cd "$OUT" && sha256sum ./*.apk | sed 's# \./# #' > SHA256SUMS) && ok "SHA256SUMS записан"

if [ "$fail" -ne 0 ]; then
  echo "ИТОГ: проверка не пройдена"
  exit 1
fi
echo "ИТОГ: все проверки пройдены"
