#!/bin/bash
# Nome: exec-sql.sh
# Descricao: Executa TODOS os .sql da pasta indicada (1º parâmetro) em ordem alfabética, em múltiplas passagens.
#            Repete enquanto houver progresso (redução das pendências). Sai quando pendências=0 ou quando
#            estagnar por N passagens consecutivas (vForceLoopMax). Durante as passagens, suprime stderr do isql;
#            em estagnação, mostra os comandos isql completos que falharam.
# Dependencias necessárias: Firebird isql, bash 4+
# Autor: Gladiston Santana <gladiston[dot]santana[at]gmail[dot]com>
# Criacao: 24/09/2025
# Atualizado em: 24/09/2025
# Licenca: GPL (GNU General Public License)

###############################################################################
# Variáveis base (mantidas conforme solicitado)
###############################################################################
BASE_DIR="$HOME/projetos-db/database/database2025-scripts"
ISQL_CMD="/opt/firebird/bin/isql"
ISQL_PARAM=" -q "
DB_FILE=database2025.fdb
DB_CONN="localhost/3050:$DB_FILE"
DB_PATH="/var/fdb"

# Controle/UX
vVerbose=true
vShowSkips=false        # -v: mostra arquivos pulados por já terem sido executados com sucesso
vForceLoopMax=3         # passagens consecutivas sem progresso para encerrar (ajustável via --force N)
vPause=false
vStopPause=false
vOKSym="OK"
vFailSym="FALHA"
SkipSym="PULO"
vHelp="
Uso: $(basename "$0") <pasta_sql> [-v] [--pause] [--quiet] [--force <N>]
Obs.: Primeiro parâmetro é obrigatório (pasta contendo .sql).
  --v : Verbose
  --pause : Uma pausa a cada execução de script
  --quiet : Modo silencioso
  --force <N> : Por padrão, quando há falhas ele repete um loop até 3 vezes para detectar estagnação,
                mas você pode mudar de 3 para outra quantidade de loops de verificação de estagnação"

###############################################################################
# Funções utilitárias
###############################################################################
print_usage() {
  echo "$vHelp"
}

handle_error() {
  echo "ERRO: $1" >&2
  exit 1
}

check_prereqs() {
  # Credenciais: Firebird usa variáveis padrão ISC_*
  if [[ -z "$ISC_USER" || -z "$ISC_PASSWORD" ]]; then
    echo "Variáveis de ambiente ISC_USER e ISC_PASSWORD devem estar configuradas."
    exit 2
  fi
  # Binário isql
  if ! command -v "$ISQL_CMD" >/dev/null 2>&1; then
    print_usage
    handle_error "isql não encontrado em '$ISQL_CMD'."
  fi
}

parse_args() {
  if [[ -z "$1" ]]; then
    print_usage
    handle_error "Primeiro parâmetro (pasta com .sql) é obrigatório."
  fi
  vSqlDir="$1"
  vSqlDir="${vSqlDir%/}"   # remove "/" final para evitar paths com "//"
  shift

  # Caminho absoluto da pasta (para que todos os arquivos fiquem absolutos)
  vSqlDirAbs="$(cd "$vSqlDir" 2>/dev/null && pwd -P)"
  [[ -z "$vSqlDirAbs" ]] && vSqlDirAbs="$vSqlDir"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pause) vPause=true;;
      -v) vShowSkips=true;;
      --quiet) vVerbose=false;;
      --force) shift; vForceLoopMax="${1:-3}";;
      -h|--help) print_usage; exit 0;;
      *) echo "Aviso: argumento desconhecido '$1'";;
    esac
    shift
  done
}

# Carrega e ordena alfabeticamente os .sql (ignora nomes iniciados com "_")
load_and_sort_files() {
  # Permite glob vazio não expandir literalmente
  shopt -s nullglob
  vAllFiles=( "$vSqlDirAbs"/*.sql )
  vFiltered=()
  for f in "${vAllFiles[@]}"; do
    b="$(basename "$f")"
    [[ "$b" == _* ]] && continue
    vFiltered+=( "$f" )
  done
  vAllFiles=( "${vFiltered[@]}" )

  [[ ${#vAllFiles[@]} -gt 0 ]] || handle_error "Nenhum .sql encontrado em $vSqlDir (após filtros)"
  IFS=$'\n' vAllFiles=($(printf '%s\n' "${vAllFiles[@]}" | sort -V)); unset IFS
}

main() {
  parse_args "$@"
  check_prereqs

  if [ ! -d "$vSqlDir" ]; then
    print_usage
    handle_error "Diretório não encontrado: $vSqlDir"
  fi

  load_and_sort_files

  echo "Base:    $BASE_DIR"
  echo "SQL dir: $vSqlDir"
  echo "Banco:   $DB_CONN"
  echo "Total de arquivos: ${#vAllFiles[@]}"

  # Estado
  declare -A vDoneOnce=()  # arquivos que já tiveram ao menos 1 execução OK (não tentar novamente)
  vPrevErrors=-1
  vContErrors=0
  vPass=0
  vSameCount=0
  vFailedList=()
  vFailedCmds=()

  while :; do
    vPass=$((vPass+1))
    vPrevErrors=$vContErrors
    vContErrors=0
    vFailedList=()
    vFailedCmds=()

    $vVerbose && echo "---- Passagem #$vPass ----"

    for vFile in "${vAllFiles[@]}"; do
      # Pula arquivos já executados com sucesso em passagens anteriores
      if [[ "${vDoneOnce[$vFile]}" == "1" ]]; then
        $vShowSkips && echo "   $vSkipSym  Pulando (já OK): $(basename "$vFile")"
        continue
      fi

      # Comando string (para diagnosticar em estagnação)
      vCmdStr="$ISQL_CMD $ISQL_PARAM \"$DB_CONN\" -i \"$vFile\""
      # Versão para exibição (encurta $HOME -> ~)
      vCmdStrDisp="${vCmdStr/$HOME/~}"
      # Execução silenciosa (suprime stderr)
      $ISQL_CMD $ISQL_PARAM "$DB_CONN" -i "$vFile" 2>/dev/null
      if [[ $? -ne 0 ]]; then
        vContErrors=$((vContErrors+1))
        vFailedList+=( "$vFile" )
        vFailedCmds+=( "$vCmdStrDisp" )
        $vVerbose && echo ">> Executando: $(basename "$vFile") [$vFailSym]"
      else
        vDoneOnce["$vFile"]=1
        $vVerbose && echo ">> Executando: $(basename "$vFile") [$vOKSym]"
      fi
      if $vPause && ! $vStopPause; then
        echo
        read -r -p "Pressione [ENTER] para ir para o próximo ou [A] para executar todos os restantes: " vResp
        if [[ "$vResp" =~ ^[Aa]$ ]]; then
          vStopPause=true
        fi
      fi
    done

    # Concluídos globais
    vDoneCount=0
    for _k in "${!vDoneOnce[@]}"; do (( vDoneCount++ )); done

    echo "Resumo passagem #$vPass: restantes=$vContErrors, concluídos acumulados=$vDoneCount/${#vAllFiles[@]}"

    # Sucesso total
    if (( vContErrors == 0 )); then
      echo "✅ Concluído sem pendências na passagem #$vPass."
      echo "Resumo final: concluídos=$vDoneCount/${#vAllFiles[@]} em $vPass passagem(ens)."
      break
    fi

    # Estagnação
    if (( vContErrors == vPrevErrors )); then
      vSameCount=$((vSameCount+1))
      if (( vSameCount >= vForceLoopMax )); then
        echo "⚠️  Progresso estagnado por $vForceLoopMax passagens consecutivas (arq. restantes: $vContErrors). Encerrando."
        if (( ${#vFailedList[@]} > 0 )); then
          echo "Comandos cmd que falharam (última passagem):"
          for i in "${!vFailedList[@]}"; do
            echo "    cmd: ${vFailedCmds[$i]}"
          done
        fi
        vPrintedPass=$((vPass-1))
        (( vPrintedPass < 1 )) && vPrintedPass=1
        echo "Resumo final: concluídos=$vDoneCount/${#vAllFiles[@]} em $vPrintedPass passagem(ens)."
        echo "Passagens executadas: $vPrintedPass (estagnação após $vForceLoopMax consecutivas sem progresso)."
        exit 1
      fi
    else
      vSameCount=0
    fi
  done
}

main "$@"
