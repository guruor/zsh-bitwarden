# zsh-bitwarden -- A Bitwarden CLI wrapper for Zsh
# https://github.com/guruor/zsh-bitwarden

# Copyright (c) 2021 Patrick Lenihan

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

_bw_pipefail() {
  # Usage _bw_pipefail ${pipestatus[@]}
  for st in "$@"; do
    if [[ "$st" -ne 0 ]]; then
      return $st
    fi
  done
}

_bw_get_alias() {
  local found_alias=$(alias | grep -E "=\W*$1\W*$" | cut -d'=' -f1)
  if [ -z "$found_alias" ]; then
    echo "$1"
  else
    echo "$found_alias"
  fi
}

_bw_test_subshell() {
  local pid=$(exec sh -c 'echo $PPID')
  if [[ "$$" == "$pid" ]]; then
    return 0
  else
    return 1
  fi
}

bw_escape_jq() {
  sed -e 's/\t/\\t/g' -e 's/\n/\\n/g' -e 's/\r/\\r/g'
}

bw_raw_jq() {
  sed -e 's/\\t/\t/g' -e 's/\\n/\n/g' -e 's/\\r/\r/g' -e 's/\\\\/\\/g'
}

export BW_DEFAULT_HEADERS="${0:h}/default-headers.csv"

bw_default_header() {
  while IFS=$'\n' read -r line; do
    local key=$(printf "%s" "$line" | awk -F, '{print $1}' | sed 's/^"//; s/"$//')
    local value=$(printf "%s" "$line" | awk -F, '{print $2}' | sed 's/^"//; s/"$//')
    if [[ "$key" == "$1" ]]; then
      printf "%s" "$value"
      return
    fi
  done < "$BW_DEFAULT_HEADERS"
  printf "%s" "$1"
  # case "$1" in
  #   ".id") printf "%s" "Item ID" ;;
  #   ".login.username"|".username") printf "%s" "Username" ;;
  #   ".login.password"|".password") printf "%s" "Password" ;;
  #   ".name") printf "%s" "Name" ;;
  #   *) printf "%s" "$1"
  # esac
}

# Takes JSON as stdin and jq paths to extract into tsv as args
bw_table() {

  local -a nskiparg harg Harg

  zparseopts -D -K -E -- \
             -nskip:=nskiparg \
             {h,-headers}+:=harg \
             {H,-rev-headers}+:=Harg \
    || return

  if [[ "$#" == 0 ]]; then
    echo "Usage: $0 [PATH]..."
    return 1
  fi

  local headers=()

  local nskip=0
  if (( $#nskiparg )); then
    nskip="${nskiparg[-1]}"
  fi

  for (( i = 1; i <= $#; i++)); do
    local header=""
    if [[ "$i" -le "$nskip" ]]; then
      header=$(bw_default_header "${(P)i}")
    elif [[   "$#harg" -ge "$(( (i - nskip) * 2 ))" ]]; then
      header="${harg[$(( (i - nskip) * 2 ))]}"
    elif [[ "1" -le "$(( (i + nskip - $#) * 2 + $#Harg ))" ]]; then
      header="${Harg[$(( (i + nskip - $#) * 2 + $#Harg ))]}"
    else
      header=$(bw_default_header "${(P)i}")
    fi
    if [[ "$header" == $'\t' ]]; then
      header=$(bw_default_header "${(P)i}")
    fi
    headers+=("$header")
  done

  local json=$(</dev/stdin)
  # Comma-join arguments
  local width=$#
  local keys="($1)? // null"
  for key in "${@:2}"; do
    keys="$keys, ($key)? // null"
  done

  local jq_output

  # Construct tsv with values selected using args
  jq_output=$(
    printf "%s" "$json" \
    | jq -rceM "to_entries | .[] | [.key] + [.value|($keys)] | select(all(.[]; . != null) and length == $width + 1) | map(tostring) | @tsv" 2> /dev/null
  ) || return $?

  if [[ -z "$jq_output" ]]; then
    echo "Error: No results." >&2
    return 1
  fi

  # Output arguments as tsv header
  printf "%s" "idx"
  for arg in "${headers[@]}"; do
    printf "\t%s" "$arg"
  done
  printf "\n"

  printf "%s\n" "$jq_output"
}

#NOTE: bw escapes \t\n
# Takes tsv as stdin and columns to show in fzf as args
_bw_select() {

  # Read input from stdin
  local tsv=$(</dev/stdin)

  # Validate that the input TSV is not empty
  if [[ -z "$tsv" ]]; then
    echo "Error: No input provided. Please provide a valid TSV input." >&2
    return 1
  fi

  # Construct a formatted table with row indices
  # local tbl=$( \
  #   printf "%s" "$tsv" \
  #   | cut -f2-
  #   | column -t -s $'\t'
  # )

  # local ids=$(
  #   printf "%s" "$tsv" | cut -f1
  # )

  local tbl=$(paste \
        <(printf "%s" "$tsv" | cut -f1) \
        <(printf "%s" "$tsv" | cut -f2- | column -t -s $'\t') \
  )


  _bw_pipefail ${pipestatus[@]}

  # Check if the table was generated correctly
  if [[ "$?" -ne 0 || -z "$tbl" ]]; then
    echo "Error: Unable to generate table. Please check the column indices." >&2
    return 1
  fi

  local row
  row=$( \
    printf "%s" "$tbl" \
    | fzf -d $'\t' --with-nth=2 --select-1 --header-lines=1 \
    | awk '{print $1}' \
  )

  _bw_pipefail ${pipestatus[@]}

  if [[ "$?" -ne 0 || -z "$row" ]]; then
    echo "Couldn't return value from fzf. Is the header line missing?" >&2
    return 2
  fi

  # Output the corresponding row from the original tsv
  printf "%s" "$row"

}

DEBUG_ARRAY_FLAG=1

debug_array() {
  (( DEBUG_ARRAY_FLAG )) || return 0
  for arg in "$@"; do
    printf "%s\n" "$arg" >&2
  done
}

bw_search() {

  local -a header_queue header_args raw_queue raw_list jqout jqtbl

  local i=1
  local -a carg=("$@")
  local curr next isout istbl

  while (( i <= $#carg )); do
    #TODO: Ordered header arguments
    curr="${carg[$i]}"
    isout=0 istbl=0
    i=$(( i + 1 ))
    if [[ "$curr" == ("-h"|"-o"|"-c"|"-O") && $#carg -ge $i ]]; then
      next="${carg[$i]}"
      i=$(( i + 1 ))
      if [[ "$curr" == "-h" ]]; then
        header_queue+=("$next")
        continue
      else
        [[ "$curr" != "-c" ]] && isout=1
        [[ "$curr" != "-O" ]] && istbl=1
      fi
    elif [[ "$curr" == "-r" ]]; then
      raw_queue+=(1)
      continue
    else
      next="$curr"
      isout=0
      istbl=1
    fi
    if (( isout )); then
      jqout+=("$next")
      if [[ "$#raw_queue" -eq 0 ]]; then
        raw_list+=(0)
      else
        raw_list+=(1)
        raw_queue=("${raw_queue[@]:1}")
      fi
    fi
    if (( istbl )); then
      jqtbl+=("$next")
      if [[ "$#header_queue" -eq 0 ]]; then
        next=$(bw_default_header "$next")
        header_args+=("-h" "$next")
      else
        header_args+=("-h" "${header_queue[1]}")
        header_queue=("${header_queue[@]:1}")
      fi
    fi
  done

  if [[ $#raw_list !=  $#jqout ]]; then
    echo "raw list error $#raw_list $#jqout" >&2
    return 1
  fi

  if [[ $#header_args != $(( $#jqtbl * 2)) ]]; then
    echo "ERROR" >&2
    return 1
  fi

  # Ensure there are visible and output fields
  if [[ "${#jqtbl}" == 0 ]]; then
      echo "No visible fields entered" >&2
    return 1
  fi
  if [[ "${#jqout}" == 0 ]]; then
    jqout=(".")
    raw_queue+=(1)
    # echo "No output fields entered" >&2
    # return 2
  fi

  # Search using bitwarden
  local items=$(</dev/stdin)

  local noitems tsv row

  noitems=$(printf "%s" "$items" | jq '. | length')

  if [ $? -ne 0 ] || [ -z "$items" ] \
       || [ "$noitems" -eq "0" ]; then
    echo "No results found in the current vault data. Run 'bwvault sync' and retry if the item changed recently." >&2
    return 4
  fi

  local -a bw_table_args
  bw_table_args+=("${header_args[@]}")
  (( $#nskiparg )) && bw_table_args+=("${nskiparg[@]}")
  bw_table_args+=("${jqtbl[@]}")

  tsv=$(printf "%s" "$items" | bw_table "${bw_table_args[@]}")

  if [ $? -ne 0 ]; then
    echo "Failed to construct tsv" >&2
    return 4
  fi

  local -a bw_select_args
  bw_select_args+=("${jqout[@]}")

  row=$(printf "%s" "$tsv" | _bw_select)


  if [ $? -ne 0 ]; then
    echo "Failed to select row" >&2
    return 4
  fi

  local item key raw entry
  local -a jq_args
  item=$(printf "%s" "$items" | jq "${jq_args[@]}" -ceM ".[$row]")

  for (( i=1; i <= $#jqout; i++ )); do
    key="($jqout[$i])?"
    jq_args=()
    (( raw_list[$i] )) && jq_args=() || jq_args=("-r")
    # strip trailing newline
    entry=$(printf "%s" "$item" | jq "${jq_args[@]}" -ceM "$key")
    printf "%s" "$entry"
    if [[ $i -ne $#jqout ]]; then
      printf "\x1F"
    fi
  done

}

bw_request_params() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  printf "?%s=%s" "$1" "$2"

  local j
  for (( i=3, j=4; i <= $#; i += 2, j += 2)); do
    printf "&%s=%s" "${(P)i}" "${(P)j}"
  done
}

bw_request() {
  local method=$1 endpoint=$2 res
  local -a data_args
  local params=$(bw_request_params "${@:3}")
  if ! [[ -t 0 ]]; then
    data_args+=("-d" "$(</dev/stdin)")
  fi

  # local res=$(wget --method="$method" --header="accept: application/json" --header="Content-Type: application/json" --body-data="${data_args[@]}" -qO- "http://localhost:8087$endpoint$params") || return $?
  res=$(curl -sX "$method" "http://localhost:8087$endpoint$params" -H 'accept: application/json' -H 'Content-Type: application/json' "${data_args[@]}") || return $?

  if ! printf "%s" "$res" | jq empty > /dev/null 2>&1; then
    printf "%s\n" "$res" >&2
    return 1
  fi

  local success=$(printf "%s" "$res" | jq -rceM .success)
  if [[ "$success" == "false" ]]; then
    printf "%s" "$res" | jq -rceM .message >&2
    return 1
  fi

  local jq_cond=$(printf "%s" "$res" | jq -ceM 'has("data")')
  if [[ "$jq_cond" == "true" ]]; then
    res=$(printf "%s" "$res" | jq -ceM .data)
  fi
  printf "%s" "$res"
}

bw_request_path() {
  local -a rarg narg

  zparseopts -D -K -E -- \
             r=rarg \
             n=narg || return

  local method="$1" endpoint="$2" jqpath="$3" res exitcode
  local params_list=("${@:4}")
  res=$(bw_request "$method" "$endpoint" "${params_list[@]}"| jq "${rarg[@]}" -ceM "$jqpath")
  _bw_pipefail ${pipestatus[@]} || return $?
  printf "%s" "$res"
  if (( !$#narg )); then
    echo
  fi
}

bw_status() {
  local res
  res=$(bw_request_path -rn GET '/status' '.template.status') || return $?
  printf "%s\n" "$res" >&2
  if [[ "$res" == "unlocked" ]]; then
    return 0
  else
    return 1
  fi
}

bw_sync() {
  local res
  bw_request_path -r POST '/sync' '.title' || return $?
}

bw_serve() {
  if ! pgrep -f "bw serve" > /dev/null 2>&1; then
    nohup bw serve > /dev/null 2> /dev/null &
    sleep 2
  fi
}

bw_unlock() {
  bw_serve

  local st
  if st=$(bw_status) 2> /dev/null; then
    return
  fi

  local pass

  echo -n "Enter your master password: " >&2

  if ! read -s pass; then
    echo
    return 1
  fi

  echo

  local res exitcode

  printf "%s" "$pass" | awk '{print "{\"password\":\"" $0 "\"}"}' | bw_request_path -r POST /unlock .title >&2

}

bw_lock() {
  bw_serve

  local st res

  if ! st=$(bw_status) 2> /dev/null; then
    return
  fi

  bw_request_path -r POST /lock .title

}

bw_generate() {
  local -a larg uarg sarg narg lengtharg
  zparseopts -D -E -F -K -- \
             {l,-lowercase}=larg \
             {u,-uppercase}=uarg \
             {s,-special}=sarg \
             {n,-number}=narg \
             -length:=lengtharg || return

  bw_unlock || return $?

  local -a param_list
  (( $#larg)) && param_list+=( "lowercase" "true" )
  (( $#uarg)) && param_list+=( "uppercase" "true" )
  (( $#sarg)) && param_list+=( "special" "true" )
  (( $#narg)) && param_list+=( "number" "true" )
  (( $#lengtharg)) && param_list+=( "length" "${lengtharg[-1]}" )

  bw_request_path -rn GET "/generate$params" .data "${param_list[@]}"
}

bw_template() {
  bw_request_path -n GET /object/template/item .template
}

bw_list_cache() {

  bw_unlock || return $?

  local res
  bw_request_path -n GET /list/object/items .data

}

bw_simplify() {

  jq -ceM "[.[] | {
     id: .id,
     name: .name,
     notes: .notes,
     username: .login.username,
     password: .login.password,
     fields: ((.fields | group_by(.name) | map({(.[0].name): map(.value)}) | add )? // {})
  }]"

}

bw_unsimplify() {
  local uuid item old_item
  item=$(jq -ceM '{
  id: .id,
  name: .name,
  notes: .notes,
  fields: [
    .fields | to_entries[] |
    .value[] as $v |
    {name: .key, value: $v, type: 0, linkedId: null}
  ],
  login: {
    username: .username,
    password: .password
  }
  }') || return $?
  uuid=$(printf "%s" "$item" | jq -rceM ".id") || return $?
  if [[ "$uuid" == "null" ]]; then
    old_item=$(bw_template) || return $?
  else
    old_item=$(bw_list_cache | bw_get_item "$uuid") || return $?
  fi
  printf "%s" "$old_item $item" | jq -ceMs ".[0] * .[1]" || return $?
}

bw_list() {
  local -a sarg sxarg jarg garg simplifyarg larg narg
  zparseopts -D -F -K -- \
             {s,-search-all}+:=sarg \
             {-search-name,-search-user,-search-pass,-search-note}+:=sxarg \
             {j,-search-jq}:=jarg \
             {g,-group-fields}=garg \
             -simplify=simplifyarg \
             {l,-login}=larg \
             {n,-note}=narg || return
  local items
  items=$(bw_list_cache) || return $?
  for (( i = 2; i <= $#sarg; i+=2)); do
    items=$(printf "%s" "$items" | jq -ceM "[.[] | select(
   reduce [ .id, .name, .notes, .login.username, .login.password, (.fields[]?.value) ][] as \$field
  (false; . or (\$field // \"\" | test(\"${sarg[$i]}\";\"i\")))
    )]") || return $?
  done
  for (( i = 1; i <= $#sxarg; i+=2)); do
    local jqpath=""
    case "${sxarg[$i]}" in
      "--search-name")
        jqpath=".name"
      ;;
      "--search-user")
        jqpath=".login.username"
        ;;
      "--search-pass")
        jqpath=".login.password"
        ;;
      "--search-notes")
        jqpath=".login.notes"
        ;;
    esac
    items=$(printf "%s" "$items" | jq -ceM "[.[] | select($jqpath | test(\"${sxarg[(( $i + 1 ))]}\";\"i\")?)]") || return $?
  done
  # local items=$(bw list items --search "${sarg[-1]}")
  if (( $#larg || $#narg)); then
    local item_type
    if (( $#larg)); then
      item_type=1
    elif (( $#narg )); then
      item_type=2
    fi
    items=$(printf "%s" "$items" | jq -ceM "[.[] | select(.type == $item_type)]") || return $?
  fi
  if (( $#simplifyarg )); then
    items=$(printf "%s" "$items" | bw_simplify) || return $?
  elif (( $#garg )); then
    items=$(printf "%s" "$items" | bw_group_fields) || return $?
  fi
  for (( i = 2; i <= $#jarg; i+=2)); do
    items=$(printf "%s" "$items" | jq -ceM "[.[] | select((${jarg[$i]})? // false)]") || return $?
  done
  # Command substitution removes newline
  printf "%s\n" "$items"
}

bw_copy() {
  if (( $+functions[clipcopy] )); then
    clipcopy
  elif command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif command -v clip.exe >/dev/null 2>&1; then
    clip.exe
  else
    print -u2 'No clipboard provider found. Install wl-clipboard/xclip on Linux or use a command output option.'
    return 1
  fi
}

bw_tsv() {
  local -a \
        itemsonlyarg \
        sarg \
        sxarg \
        jarg \
        garg \
        simplifyarg \
        larg \
        narg \
        parg \
        carg \
        targ
  zparseopts -D -K -E -- \
             -items-only=itemsonlyarg \
             {s,-search-all}+:=sarg \
             {-search-name,-search-user,-search-pass,-search-note}+:=sxarg \
             {j,-search-jq}:=jarg \
             {g,-group-fields}=garg \
             -simplify=simplifyarg \
             {l,-login}=larg \
             {n,-note}=narg \
             {p,-clipboard}=parg \
             {t,-table}=targ || return

  if (( !$#parg )) && { (( $#targ )) || ! [[ -t 1 ]]; }; then
    parg+=("-p")
  fi

  local res

  local -a bw_table_args
  (( $#nskiparg )) && bw_table_args+=("${nskiparg[@]}")

  local items
  if [[ -t 0 ]]; then
    local -a bw_list_args
    (( $#sarg )) && bw_list_args+=("${sarg[@]}")
    (( $#sxarg )) && bw_list_args+=("${sxarg[@]}")
    (( $#jarg )) && bw_list_args+=("${jarg[@]}")
    (( $#garg )) && bw_list_args+=("${garg[@]}")
    (( $#simplifyarg )) && bw_list_args+=("${simplifyarg[@]}")
    (( $#larg )) && bw_list_args+=("${larg[@]}")
    (( $#narg )) && bw_list_args+=("${narg[@]}")
    items=$(bw_list "${bw_list_args[@]}")
    if (( $#itemsonlyarg )); then
      printf "%s" "$items"
      return
    fi
  else
    items=$(</dev/stdin)
  fi

  if (( $#targ )); then
    IFS='' res=$(printf "%s" "$items" | bw_table "${bw_table_args[@]}" "$@") || return $?
  else
    local -a bw_search_args
    IFS='' res=$(printf "%s" "$items" | bw_search "${bw_table_args[@]}" "${bw_search_args[@]}" "$@") || return $?

  fi
  if (( $#parg )); then
    printf "%s" "$res"
  else
    printf "%s" "$res" | bw_copy
  fi
}

# bw_read_results() {
#   local res=$(</dev/stdin)
#   local -a values

#   IFS=$'\x1F' values=($(printf "%s" "$res"))

#   for (( i=1; i<=$#; i++)); do
#     var="${(P)i}"
#     val="${values[$i]}"
#     # echo eval "$var='$val'" | cat -A
#     eval "$var='$val'"
#   done
# }

bw_connect_wifi() {
  bw_unlock || return $?
  local -a res
  local ssids jqfilter
  ssids=$(nmcli device wifi list | grep -v 'SSID' | grep -v '|' | awk '{print $2}' | paste -sd'|')
  items=$(bw_list -l "$@" | jq -ceM "[.[] | select((.login.username | test(\"^($ssids)\$\"))?)]")
  IFS=$'\x1F' res=($(printf "%s" "$items" | bw_search -c .name -o .login.username -O .login.password))
  _bw_pipefail ${pipestatus[@]} || return $?
  user="${res[1]}" pass="${res[2]}"
  printf "%s" "$pass" | nmcli --ask c up "$user"
}

bw_user_pass() {
  local -a sarg

  bw_unlock || return $?

  local user pass
  local -a res
  IFS=$'\x1F' res=($(bw_list -l "$@" | bw_search -c .name -o .login.username -O .login.password))
  _bw_pipefail ${pipestatus[@]}
  user="${res[1]}" pass="${res[2]}"

  if [[ "$?" -ne 0 ]]; then
    return 2
  fi
  echo -n "Hit enter to copy username..."
  read _ && printf "%s" "$user" | bw_copy
  echo -n "Hit enter to copy password..."
  read _ && printf "%s" "$pass" | bw_copy
}

bw_select_values() {
  jq -rceM "[.[] | $1] | unique | .[]" \
    | fzf --header="$2" --print-query \
    | awk 'NR == 1 && $0 != "" { print $0; exit } NR == 2 { print $0; exit }'
  _bw_pipefail ${pipestatus[@]}
}

bw_select_field() {
  bw_select_values '.fields[]?.name?' "field"
}

bw_group_fields() {
  jq -ceM '[.[] | . as $item | .fields? | to_entries? | .[] as $field | $item | .fields=$field]'
}

# bw_field_old() {

#   local -a sarg farg
#   zparseopts -D -K -E -- \
#              {p,-clipboard}=parg \
#              {f,-field}:=farg || return

#   local items=$(bw_list -g "$@")

#   local name
#   if (( $#farg)); then
#     name="${farg[-1]}"
#   else
#     name=$(printf "%s" "$items" | bw_select_field)
#   fi

#   #local fieldpath="[.fields[] | select(.name == \"$name\") | .value] | first"
#   local fieldpath=".fields.value | select(.name == \"$name\") | .value"

#   local res=$(printf "%s" "$items" | bw_search \
#                                        -c .name \
#                                        -H "$name" -o "$fieldpath")
#   if (( $#parg )); then
#     printf "%s" "$res"
#   else
#     printf "%s" "$items" | bw_copy
#   fi
# }

bw_field() {

  local -a rarg parg farg choosearg
  zparseopts -D -K -E -- \
             {p,-clipboard}=parg \
             {f,-field}:=farg \
             -choose=choosearg || return

  local items
  items=$(bw_tsv -p --items-only  --simplify "$@") || return $?

  local res item name

  if (( $#farg || $#choosearg )); then
    if (( $#farg )); then
      name="${farg[-1]}"
    elif (( $#choosearg)); then
      name=$(printf "%s" "$items" | bw_select_values '.fields | keys_unsorted | .[]' "field") || return $?
    fi
    item=$(printf "%s" "$items" | bw_tsv \
                                   -r -O . \
                                   -c .name \
                                   -h "$name" -c ".fields[\"$name\"] | select(length > 0) | join(\", \")" "$@") || return $?
  else
    item=$(printf "%s" "$items" | bw_tsv \
                                   -r -O . \
                                   -c .name \
                                   -h fields -c ".fields | keys_unsorted | select(length > 0) | join(\", \")" "$@" \
                                   ) || return $?
    name=$(printf "%s" "$item" | jq -ceM ".fields | to_entries" | bw_search \
                                 -h field -o '.key' \
                                 -h value -c '.value | join(", ")') || return $?
  fi

  res=$(printf "%s" "$item" | jq -ceM ".fields[\"$name\"]" | bw_search -h "$name" -o .)
  _bw_pipefail ${pipestatus[@]}

  if (( $#parg )); then
    printf "%s" "$res"
  else
    printf "%s" "$res" | bw_copy
  fi

}

bw_get_item() {
  jq -ceM ".[] | select(.id == \"$1\")$2"
}

bw_edit_json() {
  local item=$(</dev/stdin)
  local uuid
  uuid=$(printf "%s" "$item" | jq -rceM ".id") || return $?
  if [[ "$uuid" == "null" ]]; then
    printf "%s" "$item" | bw_request POST /object/item
  else
    printf "%s" "$item" | bw_request PUT "/object/item/$uuid"
  fi
}

bw_edit_item() {
  # bw_reset_cache_list
  jq -ceM "$2" | bw_request PUT "/object/item/$1"
}

bw_edit_item_assign() {

  bw_edit_item "$1" "$2 = \"$3\""

}

bw_edit_item_append() {

  bw_edit_item "$1" "$2 += [$3]"

}

bw_edit_field() {

  local -a narg rarg darg farg
  zparseopts -D -K -E -- \
             {n,-new}=narg \
             {r,-rename}=rarg \
             {d,-delete}=darg \
             {f,-field}:=farg || return

  bw_unlock || return $?

  local items
  items=$(bw_tsv -p --items-only  --simplify "$@") || return $?

  local -a res
  local item
  local name

  if (( $#farg || $#choosearg )); then
    if (( $#farg )); then
      name="${farg[-1]}"
    elif (( $#choosearg)); then
      name=$(printf "%s" "$items" | bw_select_values '.fields | keys_unsorted | .[]' "field") || return $?
    fi
    item=$(printf "%s" "$items" | bw_tsv \
                                   -r -O . \
                                   -c .name \
                                   -h "$name" -c ".fields[\"$name\"] | select(length > 0) | join(\", \")" "$@") || return $?
  else
    item=$(printf "%s" "$items" | bw_tsv \
                                   -r -O . \
                                   -c .name \
                                   -h fields -c ".fields | keys_unsorted | select(length > 0) | join(\", \")" "$@" \
                                   ) || return $?
    name=$(printf "%s" "$item" | jq -ceM ".fields | to_entries" | bw_search \
                                 -h field -o '.key' \
                                 -h value -c '.value | join(", ")') || return $?
  fi

  local item uuid idx value
  uuid=$(printf "%s" "$item" | jq -rceM ".id")

  IFS=$'\x1F' res=($(printf "%s" "$item" | jq -ceM ".fields[\"$name\"] | to_entries" | bw_search -O .key -h "$name" -o .value))
  _bw_pipefail ${pipestatus[@]}

  # printf "%s" "$res" | bw_read_results idx val || return $?
  idx="${res[1]}" val="${res[2]}"

  item=$(printf "%s" "$item" | jq -ceM ". | del(.fields.${name}[$idx])")

  if (( $#darg)); then
    printf "%s" "$item" | bw_edit_item "$uuid" "del(.fields[$idx])"
    _bw_pipefail ${pipestatus[@]}
    return $?
  fi
  if (( $#rarg)); then
    if [[ -t 0 ]]; then
      vared -p "Edit field name: " name
    else
      name=$(</dev/stdin)
    fi
  else
    if [[ -t 0 ]]; then
      vared -p "Edit field $name: " val
    else
      val=$(</dev/stdin)
    fi
  fi

  printf "%s" "$item" | jq -ceM ". | .fields.${name}+=[\"$val\"]" | bw_unsimplify | bw_edit_json

  _bw_pipefail ${pipestatus[@]}

}

bw_add_field() {

  local -a farg
  zparseopts -D -K -E -- \
             {f,-field}:=farg || return

  bw_unlock || return $?

  local -a res
  local items item name val
  items=$(bw_list "$@") || return $?
  if (( $#farg)); then
    name="${farg[-1]}"
  else
    name=$(printf "%s" "$items" | bw_select_field) || return $?
  fi
  local path_val="[(.fields[] | select(.name == \"$name\") | .value) // \"\"] | first"
  IFS=$'\x1F' res=($(printf "%s" "$items" | bw_search \
                                 -r -O . \
                                 -O .id -c .name \
                                 -h "$name" -o "$path_val")) || return $?
  if [[ $? -ne 0 ]]; then
    echo "Couldn't find items with search args $@" >&2
    return 1
  fi
  # printf "%s" "$res" | bw_read_results item uuid val || return $?
  item="${res[1]}" uuid="${res[2]}" val="${res[3]}"
  if [[ -t 0 ]]; then
    vared -p "Field value: " val
  else
    val=$(</dev/stdin)
  fi
  local field_json="{\"name\": \"$name\", \"value\": \"$val\"}"
  printf "%s" "$item" | bw_edit_item_append "$uuid" ".fields" "$field_json"
}

bw_edit_name() {

  bw_unlock || return $?

  local items item uuid val res
  items=$(bw_list -l "$@") || return $?
  IFS=$'\x1F' res=($(printf "%s" "$items" | bw_search \
                                 -r -O . \
                                 -o .name \
                                 -c .login.username \
                                 -O .id)) || return $?
  if [[ $? -ne 0 ]]; then
    echo "Couldn't find items with search strings $@" >&2
    return 1
  fi
  local -a values
  item="${res[1]}" val="${res[2]}" uuid="${res[3]}"
  # printf "%s" "$res" | bw_read_results item val uuid || return $?
  if [[ -t 0 ]]; then
    val=$(printf "%s" "$val" | bw_raw_jq)
    vared -p "Edit name: " val
  else
    val=$(</dev/stdin)
  fi
  val=$(printf "%s" "$val" | bw_escape_jq)
  printf "%s" "$item" | bw_edit_item_assign "$uuid" ".name" "$val"
  _bw_pipefail ${pipestatus[@]}
}

bw_filter_type() {
  local -a larg narg
  zparseopts -D -F -K -- \
             {l,-login}=larg \
             {n,-note}=narg || return
  local item_type
  if (( $#larg)); then
    item_type=1
  elif (( $#narg )); then
    item_type=2
  else
    return 1
  fi
  jq -ceM "[.[] | select(.type == $item_type)]"
}

bw_edit_username() {

  bw_unlock || return $?

  local -a res
  local items item uuid val
  items=$(bw_list -l "$@") || return $?
  IFS=$'\x1F' res=($(printf "%s" "$items" | bw_search \
                                 -r -O . \
                                 -c .name \
                                 -o .login.username \
                                 -O .id)) || return $?
  if [[ $? -ne 0 ]]; then
    echo "Couldn't find items with search args $@" >&2
    return 1
  fi
  # printf "%s" "$res" | bw_read_results item val uuid || return $?
  item="${res[1]}" val="${res[2]}" uuid="${res[3]}"
  if [[ -t 0 ]]; then
    val=$(printf "%s" "$val" | bw_raw_jq)
    vared -p "Edit username: " val
  else
    val=$(</dev/stdin)
  fi
  val=$(printf "%s" "$val" | bw_escape_jq)
  printf "%s" "$item" | bw_edit_item_assign "$uuid" .login.username "$val"
  _bw_pipefail ${pipestatus[@]}
}

bw_edit_password() {

  bw_unlock || return $?

  local -a res
  local items item uuid val

  items=$(bw_list -l "$@") || return $?

  IFS=$'\x1F' res=($(printf "%s" "$items" | bw_search \
                                 -r -O . \
                                 -c .name \
                                 -c .login.username \
                                 -O .id -O .login.password)) || return $?
  if [[ $? -ne 0 ]]; then
    echo "Couldn't find items with search args $@" >&2
    return 1
  fi
  # printf "%s" "$res" | bw_read_results item val uuid || return $?
  item="${res[1]}" uuid="${res[2]}" val="${res[3]}"
  if [[ -t 0 ]]; then
    val=$(printf "%s" "$val" | bw_raw_jq)
    echo -n "Enter password: " >&2
    read -s val
    echo
    local dup
    echo -n "Enter password again: " >&2
    read -s dup
    echo
    if [[ "$val" != "$dup" ]]; then
      echo "Passwords don't match" >&2
      return 1
    fi
    # vared -p "Edit password: " val
  else
    val=$(</dev/stdin)
  fi
  val=$(printf "%s" "$val" | bw_escape_jq)
  printf "%s" "$item" | bw_edit_item_assign "$uuid" .login.password "$val"
  _bw_pipefail ${pipestatus[@]}
}

bw_edit_note() {

  bw_unlock || return $?

  local -a res
  local items uuid val

  items=$(bw_list -n "$@") || return $?
  IFS=$'\x1F' res=($(printf "%s" "$items" | bw_search \
                                 -r -O . \
                                 -c .name \
                                 -o .notes -O .id)) || return $?

  # printf "%s" "$res" | bw_read_results item val uuid || return $?
  item="${res[1]}" val="${res[2]}" uuid="${res[3]}"
  if [[ -t 0 ]]; then
    val=$(printf "%s" "$val" | bw_raw_jq)
    vared -p $'Edit note |\n-----------\n' val
  else
    val=$(</dev/stdin)
  fi
  val=$(printf "%s" "$val" | bw_escape_jq)
  printf "%s" "$item" | bw_edit_item_assign "$uuid" .notes "$val"
  _bw_pipefail ${pipestatus[@]}
}

bw_create_login() {

  local -a narg uarg
  zparseopts -D -F -K -- \
             {n,-name}:=narg \
             {u,-username}:=uarg || return

  bw_unlock || return $?

  local name username uuid
  if (( $#narg)); then
    name=$(printf "%s" "$name" | bw_raw_jq)
    name="${narg[-1]}"
  else
    vared -p "Login item name: " name
  fi
  name=$(printf "%s" "$name" | bw_escape_jq)
  if (( $#uarg)); then
    username="${uarg[-1]}"
  else
    username=$(printf "%s" "$username" | bw_raw_jq)
    vared -p "Login item username: " username
  fi
  username=$(printf "%s" "$username" | bw_escape_jq)
  local pass
  if [ -t 0 ] ; then
    pass="$(bw_generate -ulns --length 21)"
  else
    pass="$(</dev/stdin)"
  fi
  val=$(printf "%s" "$val" | bw_escape_jq)
  # bw_reset_cache_list
  # bw_template \
  #   | jq -ceM ".name=\"${name}\" | .login.username=\"$username\" | .login.password=\"$pass\"" \
  #   | bw encode | bw create item | jq -rceM '.login.password'
  bw_template \
      | jq -ceM ".name=\"${name}\" | .login.username=\"$username\" | .login.password=\"$pass\"" \
      | bw_request POST "/object/item" | jq -rceM '.login.password'
  _bw_pipefail ${pipestatus[@]}
}

bw_create_note() {

  local -a narg
  zparseopts -D -F -K -- \
             {n,-name}:=narg || return

  bw_unlock || return $?

  local name val uuid
  if (( $#narg)); then
    name="${narg[-1]}"
  else
    name=$(printf "%s" "$name" | bw_raw_jq)
    vared -p "Note item name: " name
  fi
  name=$(printf "%s" "$name" | bw_escape_jq)
  if [[ -t 0 ]]; then
    val=$(printf "%s" "$val" | bw_raw_jq)
    vared -p $'Enter note |\n-----------\n' val
  else
    val=$(</dev/stdin)
  fi
  val=$(printf "%s" "$val" | bw_escape_jq)
  # bw_reset_cache_list
  # uuid=$(bw_template \
  #          | jq ".name=\"${name}\" | .notes=\"${val}\" | .type=2 | .secureNote.type = 0" \
  #          | bw encode | bw create item | jq -r '.id')
  uuid=$(bw_template \
             | jq ".name=\"${name}\" | .notes=\"${val}\" | .type=2 | .secureNote.type = 0" \
             | bw_request POST /object/item | jq -r '.id')
  _bw_pipefail ${pipestatus[@]}
}

bw_init_file() {
  local itemfile=$(mktemp)
  chmod 600 "$itemfile"
  cat > "$itemfile"
  printf "%s" "$itemfile"
}

_bw_remove_temp() {
  [[ -n "$1" && -e "$1" ]] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u -- "$1"
  elif [[ "$OSTYPE" == darwin* ]]; then
    rm -Pf -- "$1" 2>/dev/null || rm -f -- "$1"
  else
    rm -f -- "$1"
  fi
}

bw_edit_file() {
  local modtime_before modtime_after editor_status

  modtime_before=$(date -r "$1" +"%s")
  $EDITOR "$1"
  editor_status=$?
  if (( editor_status != 0 )); then
    _bw_remove_temp "$1"
    return $editor_status
  fi
  modtime_after=$(date -r "$1" +"%s")

  if [[ "$modtime_before" -eq "$modtime_after" ]]; then
    _bw_remove_temp "$1"
    return 1
  fi
}

bw_json_edit() {
  bw_unlock || return $?
  local -a simplifyarg narg
  zparseopts -D -K -E -- \
             {n,-new}=narg \
             -simplify=simplifyarg || return

  local item itemfile

  if (( $#narg )); then
    item=$(bw_template)
    if (( $#simplifyarg )); then
      item=$(printf "%s" "$item" | jq -ceM "[.]" | bw_simplify)
      _bw_pipefail ${pipestatus[@]} || return $?
    fi
  else
    item=$(bw_tsv -p -r -O . -c .name "$@" "${simplifyarg[@]}") || return $?
  fi
  item=$(printf "%s" "$item" | jq -M)
  itemfile=$(printf "%s" "$item" | bw_init_file) || return $?
  if ! bw_edit_file "$itemfile"; then
    _bw_remove_temp "$itemfile"
    return 1
  fi
  item=$(<"$itemfile")
  _bw_remove_temp "$itemfile"
  if (( $#simplifyarg )); then
    item=$(printf "%s" "$item" | bw_unsimplify) || return $?
  fi
  printf "%s" "$item" | bw_edit_json || return $?
  # bw_reset_cache_list
}

create_temp_yaml_file() {
  local content="$1"
  local tempfile="$(mktemp)"
  mv "${tempfile}" "${tempfile}.yml"
  tempfile=""${tempfile}.yml""
  chmod 600 "$tempfile"
  print -r -- "$content" > "$tempfile"
  printf "%s" "$tempfile"
}

bw_notes_field_edit_as_yaml() {
  bw_unlock || return $?
  local -a simplifyarg narg
  zparseopts -D -K -E -- {n,-new}=narg -simplify=simplifyarg || return

  local item notes itemfile new_notes

  if (( $#narg )); then
    item=$(bw_template)
  else
    item=$(bw_tsv -p -r -O . -c .name "$@") || return $?
  fi

  notes=$(printf "%s" "$item" | jq -r '.notes // ""')

  if echo "$notes" | yq -e . &>/dev/null; then
    notes=$(echo "$notes" | yq eval '.' -)
  fi

  itemfile=$(create_temp_yaml_file "$notes") || return $?
  if ! bw_edit_file "$itemfile"; then
    _bw_remove_temp "$itemfile"
    return 1
  fi

  new_notes=$(<"$itemfile")
  _bw_remove_temp "$itemfile"

  updated_item=$(printf "%s" "$item" | jq --arg notes "$new_notes" '.notes = $notes')
  printf "%s" "$updated_item" | bw_edit_json || return $?
}

# -------------------------------------------------------------------
# Bitwarden ENV secrets
# -------------------------------------------------------------------

BWENV_PREFIX="${BWENV_PREFIX:-BWENV_}"
BWENV_KEYRING_BIN="${BWENV_KEYRING_BIN:-${0:h}/bin/bwenv-keyring}"
BWENV_KEYRING_SERVICE="${BWENV_KEYRING_SERVICE:-zsh-bitwarden}"

_bwenv_require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print -u2 "bwenv requires '$1'."
        return 1
    fi
}

_bwenv_require_keyring() {
    if [[ ! -x "$BWENV_KEYRING_BIN" ]]; then
        print -u2 "bwenv keyring helper is not executable: $BWENV_KEYRING_BIN"
        print -u2 "Run 'bwenv doctor' for setup guidance."
        return 1
    fi
}

_bw_session() {
    # Reuse an existing session if the caller intentionally has one.
    if [[ -n "${BW_SESSION:-}" ]]; then
        print -r -- "$BW_SESSION"
        return
    fi

    # Otherwise unlock only for this operation.
    # BW_SESSION is NOT globally exported.
    bw unlock --raw
}

_bwenv_normalize_name() {
    local name="$1"

    if [[ "$name" == "${BWENV_PREFIX}"* ]]; then
        print -r -- "${name#$BWENV_PREFIX}"
    else
        print -r -- "$name"
    fi
}

_bwenv_item_name() {
    local name="$1"

    if [[ "$name" == "${BWENV_PREFIX}"* ]]; then
        print -r -- "$name"
    else
        print -r -- "${BWENV_PREFIX}${name}"
    fi
}

_bwenv_validate_name() {
    [[ "$1" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]]
}

_bwenv_select_names() {
    local session="$1" candidates selected line

    _bwenv_require fzf || return 1
    candidates="$(
        setopt localoptions pipefail
        BW_SESSION="$session" bw list items 2>/dev/null \
            | jq -r --arg prefix "$BWENV_PREFIX" '
                .[]
                | select(.name | startswith($prefix))
                | [
                    (.name[($prefix | length):]),
                    .name,
                    (if ((.login.password? // "") | length) > 0 then "login password"
                     elif ((.notes? // "") | length) > 0 then "secure note"
                     else "no usable value" end)
                  ]
                | @tsv
            '
    )" || {
        print -u2 "Unable to list Bitwarden items from the current vault data."
        print -u2 "Run 'bw sync' and retry."
        return 1
    }

    if [[ -z "$candidates" ]]; then
        print -u2 "No Bitwarden items use the '$BWENV_PREFIX' prefix in the current vault data."
        print -u2 "Run 'bw sync' and retry if items were added recently."
        return 1
    fi

    selected="$(
        print -r -- "$candidates" \
            | fzf --multi --delimiter=$'\t' --with-nth=1,2,3 \
                  --header='Select environment variables (values are never displayed)'
    )"
    if [[ $? -ne 0 || -z "$selected" ]]; then
        return 130
    fi

    reply=()
    for line in ${(f)selected}; do
        reply+=("${line%%$'\t'*}")
    done
}

_bwenv_source_names() {
    local session="$1"
    shift

    if (( $# > 0 )); then
        reply=("$@")
    elif [[ -n "${BW_ENV_SECRETS:-}" ]]; then
        reply=(${=BW_ENV_SECRETS})
    else
        _bwenv_select_names "$session" || return $?
    fi
}

_bwenv_local_names() {
    if (( $# > 0 )); then
        reply=("$@")
    elif [[ -n "${BW_ENV_SECRETS:-}" ]]; then
        reply=(${=BW_ENV_SECRETS})
    else
        print -u2 "Specify environment variable names or set BW_ENV_SECRETS."
        return 1
    fi
}

_bwenv_get_value() {
    local session="$1" requested_name="$2" item_name item
    item_name="$(_bwenv_item_name "$requested_name")"

    item="$(BW_SESSION="$session" bw get item "$item_name" 2>/dev/null)" || {
        print -u2 "Unable to find a unique Bitwarden item named '$item_name' in the current vault data."
        print -u2 "Run 'bw sync' and retry; if it is still missing, verify the item name and BWENV_PREFIX."
        return 1
    }

    REPLY="$(
        jq -er '
            if ((.login.password? // "") | length) > 0 then .login.password
            elif ((.notes? // "") | length) > 0 then .notes
            else error("no usable value") end
        ' <<< "$item"
    )" || {
        print -u2 "Bitwarden item '$item_name' has no non-empty login password or note."
        return 1
    }
}

_bwenv_export() {
    _bwenv_require bw || return 1
    _bwenv_require jq || return 1

    local session requested_name env_name
    local count=0 failed=0
    local -a names
    session="$(_bw_session)" || return 1
    _bwenv_source_names "$session" "$@" || return $?
    names=("${reply[@]}")

    for requested_name in "${names[@]}"; do
        env_name="$(_bwenv_normalize_name "$requested_name")"
        if ! _bwenv_validate_name "$env_name"; then
            print -u2 "Invalid environment variable name: $env_name"
            (( ++failed ))
            continue
        fi
        if ! _bwenv_get_value "$session" "$requested_name"; then
            (( ++failed ))
            continue
        fi
        typeset -gx "$env_name=$REPLY"
        (( ++count ))
        print "Exported: $env_name"
    done

    (( count > 0 )) || return 1
    print "Exported $count secret(s) from Bitwarden into this shell."
    (( failed == 0 ))
}

_bwenv_store() {
    _bwenv_require bw || return 1
    _bwenv_require jq || return 1
    _bwenv_require_keyring || return 1

    local session requested_name env_name
    local count=0 failed=0
    local -a names
    session="$(_bw_session)" || return 1
    _bwenv_source_names "$session" "$@" || return $?
    names=("${reply[@]}")

    for requested_name in "${names[@]}"; do
        env_name="$(_bwenv_normalize_name "$requested_name")"
        if ! _bwenv_validate_name "$env_name"; then
            print -u2 "Invalid environment variable name: $env_name"
            (( ++failed ))
            continue
        fi
        if ! _bwenv_get_value "$session" "$requested_name"; then
            (( ++failed ))
            continue
        fi
        if ! print -rn -- "$REPLY" | BWENV_KEYRING_SERVICE="$BWENV_KEYRING_SERVICE" "$BWENV_KEYRING_BIN" put "$env_name"; then
            print -u2 "Unable to store '$env_name' in the configured keyring."
            (( ++failed ))
            continue
        fi
        (( ++count ))
        print "Stored in keyring: $env_name"
    done

    (( count > 0 )) || return 1
    print "Stored $count secret(s). Use 'bwenv load' to avoid unlocking Bitwarden again."
    (( failed == 0 ))
}

_bwenv_load() {
    _bwenv_require_keyring || return 1

    local requested_name env_name value
    local count=0 failed=0
    local -a names
    _bwenv_local_names "$@" || return 1
    names=("${reply[@]}")

    for requested_name in "${names[@]}"; do
        env_name="$(_bwenv_normalize_name "$requested_name")"
        if ! _bwenv_validate_name "$env_name"; then
            print -u2 "Invalid environment variable name: $env_name"
            (( ++failed ))
            continue
        fi
        value="$(BWENV_KEYRING_SERVICE="$BWENV_KEYRING_SERVICE" "$BWENV_KEYRING_BIN" get "$env_name" 2>/dev/null)" || {
            print -u2 "Not found in the configured keyring: $env_name"
            print -u2 "Run 'bwenv store $env_name' to retrieve it from Bitwarden."
            (( ++failed ))
            continue
        }
        typeset -gx "$env_name=$value"
        (( ++count ))
        print "Loaded: $env_name"
    done

    (( count > 0 )) || return 1
    print "Loaded $count secret(s) from the keyring into this shell."
    (( failed == 0 ))
}

_bwenv_remove() {
    _bwenv_require_keyring || return 1

    local requested_name env_name
    local count=0 failed=0
    local -a names
    _bwenv_local_names "$@" || return 1
    names=("${reply[@]}")

    for requested_name in "${names[@]}"; do
        env_name="$(_bwenv_normalize_name "$requested_name")"
        if ! _bwenv_validate_name "$env_name"; then
            print -u2 "Invalid environment variable name: $env_name"
            (( ++failed ))
            continue
        fi
        if ! BWENV_KEYRING_SERVICE="$BWENV_KEYRING_SERVICE" "$BWENV_KEYRING_BIN" delete "$env_name" 2>/dev/null; then
            print -u2 "Not found in the configured keyring: $env_name"
            (( ++failed ))
            continue
        fi
        (( ++count ))
        print "Removed from keyring: $env_name"
    done

    (( count > 0 )) || return 1
    (( failed == 0 ))
}

_bwenv_unset() {
    local requested_name env_name
    local -a names
    _bwenv_local_names "$@" || return 1
    names=("${reply[@]}")

    for requested_name in "${names[@]}"; do
        env_name="$(_bwenv_normalize_name "$requested_name")"
        if ! _bwenv_validate_name "$env_name"; then
            print -u2 "Invalid environment variable name: $env_name"
            continue
        fi
        unset "$env_name"
        print "Unset: $env_name"
    done
}

_bwenv_doctor() {
    local failed=0 command_name
    for command_name in bw jq fzf python3; do
        if command -v "$command_name" >/dev/null 2>&1; then
            print "ok: $command_name"
        else
            print "missing: $command_name"
            (( ++failed ))
        fi
    done

    if [[ -x "$BWENV_KEYRING_BIN" ]]; then
        if BWENV_KEYRING_SERVICE="$BWENV_KEYRING_SERVICE" "$BWENV_KEYRING_BIN" status; then
            print "ok: keyring helper $BWENV_KEYRING_BIN"
        else
            print -u2 "unavailable: Python keyring backend"
            print -u2 "Install it with: python3 -m pip install --user keyring"
            (( ++failed ))
        fi
    else
        print -u2 "missing or not executable: $BWENV_KEYRING_BIN"
        (( ++failed ))
    fi
    (( failed == 0 ))
}

_bwenv_help() {
    case "${1:-}" in
        export)
            print -r -- 'Usage: bwenv export [NAME ...]
Export Bitwarden items named BWENV_<NAME> into the current shell.
With no names, BW_ENV_SECRETS is used; otherwise fzf provides safe multi-selection.
This command never syncs automatically. Run `bw sync` when vault data may be stale.'
            ;;
        store)
            print -r -- 'Usage: bwenv store [NAME ...]
Retrieve secrets from Bitwarden once and store them in the OS keyring.
Secret values are passed to the keyring helper over stdin and are never shown in fzf.'
            ;;
        load)
            print -r -- 'Usage: bwenv load [NAME ...]
Load secrets from the OS keyring into the current shell without contacting Bitwarden.
With no names, BW_ENV_SECRETS must be configured.'
            ;;
        remove)
            print -r -- 'Usage: bwenv remove [NAME ...]
Delete secrets from the OS keyring. Bitwarden items are not changed.'
            ;;
        unset)
            print -r -- 'Usage: bwenv unset [NAME ...]
Remove variables from the current shell. The keyring and Bitwarden are not changed.'
            ;;
        doctor)
            print -r -- 'Usage: bwenv doctor
Check required commands and the configured Python keyring backend without reading secrets.'
            ;;
        *)
            print -r -- 'Usage: bwenv <command> [arguments]

Commands:
  export   Bitwarden -> current shell
  store    Bitwarden -> OS keyring
  load     OS keyring -> current shell
  remove   delete values from the OS keyring
  unset    remove values from the current shell
  status   show configuration and keyring availability
  doctor   check dependencies without reading secrets
  help     show this help or help for a command

Reads never sync automatically. Run `bw sync` explicitly when vault data may be stale.'
            ;;
    esac
}

bwenv() {
    local command_name="${1:-help}"
    (( $# > 0 )) && shift

    case "$command_name" in
        export) _bwenv_export "$@" ;;
        store) _bwenv_store "$@" ;;
        load) _bwenv_load "$@" ;;
        remove) _bwenv_remove "$@" ;;
        unset) _bwenv_unset "$@" ;;
        status)
            print "prefix: $BWENV_PREFIX"
            print "configured names: ${BW_ENV_SECRETS:-<none>}"
            print "keyring service: $BWENV_KEYRING_SERVICE"
            print "keyring helper: $BWENV_KEYRING_BIN"
            [[ -x "$BWENV_KEYRING_BIN" ]] && BWENV_KEYRING_SERVICE="$BWENV_KEYRING_SERVICE" "$BWENV_KEYRING_BIN" status
            return 0
            ;;
        doctor) _bwenv_doctor ;;
        help|-h|--help) _bwenv_help "${1:-}" ;;
        *)
            print -u2 "Unknown bwenv command: $command_name"
            print -u2 "Run 'bwenv help' to see available commands."
            return 2
            ;;
    esac
}

# -------------------------------------------------------------------
# Bitwarden-backed persistent secret files
# -------------------------------------------------------------------

BWFILE_PREFIX="${BWFILE_PREFIX:-BWFILE_}"

_bwfile_require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 "bwfile requires '$1'."
    return 1
  fi
}

_bwfile_require_tools() {
  _bwfile_require bw && _bwfile_require jq && _bwfile_require yq && _bwfile_require mktemp
}

_bwfile_normalize_name() {
  local name="${1#$BWFILE_PREFIX}"
  name="${(U)name}"
  name="${name//[^A-Z0-9]/_}"
  while [[ "$name" == *__* ]]; do name="${name//__/_}"; done
  name="${name##_}"
  name="${name%%_}"
  print -r -- "$name"
}

_bwfile_item_name() {
  local name="$(_bwfile_normalize_name "$1")"
  [[ -n "$name" ]] || return 1
  print -r -- "${BWFILE_PREFIX}${name}"
}

_bwfile_valid_mode() {
  [[ "$1" =~ '^0[0-7]{3}$' ]] || return 1
  (( (8#$1 & 8#0137) == 0 ))
}

_bwfile_file_mode() {
  local mode numeric_mode
  local -a stat_details
  if zmodload zsh/stat 2>/dev/null && zstat -L -A stat_details +mode -- "$1" 2>/dev/null; then
    numeric_mode="${stat_details[1]}"
    printf '0%03o' "$(( numeric_mode & 8#0777 ))"
    return 0
  fi
  mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || \
    mode="$(stat -f '%Lp' -- "$1" 2>/dev/null)" || return 1
  [[ "$mode" =~ '^[0-7]{3,4}$' ]] || return 1
  printf '0%03o' "$(( 8#$mode ))"
}

_bwfile_parse_metadata() {
  local item_name="$1" notes="$2" metadata version
  metadata="$(print -rn -- "$notes" | yq eval -o=json '.' - 2>/dev/null)" || return 2
  version="$(print -rn -- "$metadata" | jq -er '.version | select(type == "number")' 2>/dev/null)" || return 2
  [[ "$version" == 1 ]] || return 3
  REPLY="$(print -rn -- "$metadata" | jq -cer --arg name "$item_name" '
    def safe_string:
      type == "string" and (test("[\u0000-\u001f\u007f]") | not);
    select(type == "object")
    | select((keys - ["description", "lifecycle", "mode", "path", "version"]) | length == 0)
    | select(.version == 1)
    | select(.path | safe_string and length > 0)
    | select(.mode | safe_string and test("^0[0-7]{3}$"))
    | select(.lifecycle == "provision" or .lifecycle == "recovery")
    | select((has("description") | not) or (.description | safe_string))
    | {name: $name, version, path, mode, lifecycle, description: (.description // "")}
  ' 2>/dev/null)" || return 2
  _bwfile_valid_mode "$(print -rn -- "$REPLY" | jq -r '.mode')" || return 4
}

_bwfile_metadata_yaml() {
  local configured_path="$1" mode="$2" lifecycle="$3" description="$4"
  jq -cn --arg path "$configured_path" --arg mode "$mode" --arg lifecycle "$lifecycle" \
    --arg description "$description" '
      {version: 1, path: $path, mode: $mode, lifecycle: $lifecycle}
      + (if $description == "" then {} else {description: $description} end)
    ' | yq eval -P '.' -
}

_bwfile_resolve_path() {
  local configured="$1" expanded component current
  [[ -n "$configured" && "$configured" != / ]] || return 1
  if [[ "$configured" == '~' ]]; then
    return 1
  elif [[ "$configured" == '~/'* ]]; then
    expanded="$HOME/${configured#\~/}"
  elif [[ "$configured" == /* ]]; then
    expanded="$configured"
  else
    return 1
  fi
  expanded="${expanded:a}"
  [[ "$expanded" != / ]] || return 1
  current=""
  for component in "${(@s:/:)expanded}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || return 2
  done
  REPLY="$expanded"
}

_bwfile_text_file() {
  jq -eRs 'index("\u0000") == null' "$1" >/dev/null 2>&1 || return 1
  cmp -s -- "$1" <(jq -jRs '.' "$1" 2>/dev/null)
}

_bwfile_inventory() {
  local session="$1" items encoded id name notes parse_status metadata
  setopt localoptions pipefail
  items="$(
    BW_SESSION="$session" bw list items 2>/dev/null \
      | jq -cr --arg prefix "$BWFILE_PREFIX" \
          '.[] | select(.type == 2 and (.name | startswith($prefix))) | {id, name, notes} | @json | @base64'
  )" || {
    print -u2 'Unable to list bwfile items from the current vault data.'
    return 1
  }
  [[ -n "$items" ]] || return 0
  while IFS= read -r encoded; do
    id="$(print -rn -- "$encoded" | jq -Rr '@base64d | fromjson | .id')" || continue
    name="$(print -rn -- "$encoded" | jq -Rr '@base64d | fromjson | .name | gsub("[\u0000-\u001f\u007f]"; "?")')" || continue
    notes="$(print -rn -- "$encoded" | jq -Rr '@base64d | fromjson | .notes // ""')" || continue
    _bwfile_parse_metadata "$name" "$notes"
    parse_status=$?
    if (( parse_status == 0 )); then
      print -rn -- "$REPLY" | jq -c --arg id "$id" '. + {id: $id, valid: true}'
    else
      case "$parse_status" in
        3) metadata='unsupported metadata version' ;;
        4) metadata='unsafe mode' ;;
        *) metadata='invalid metadata' ;;
      esac
      jq -cn --arg id "$id" --arg name "$name" --arg error "$metadata" \
        '{id: $id, name: $name, valid: false, error: $error}'
    fi
  done <<< "$items"
}

_bwfile_find() {
  local session="$1" requested="$2" item_name inventory count
  item_name="$(_bwfile_item_name "$requested")" || {
    print -u2 'Invalid bwfile logical name.'
    return 1
  }
  inventory="$(_bwfile_inventory "$session")" || return 1
  count="$(print -rn -- "$inventory" | jq -s --arg name "$item_name" '[.[] | select(.name == $name)] | length')" || return 1
  [[ "$count" == 1 ]] || {
    print -u2 "Unable to find a unique Bitwarden item named '$item_name'."
    print -u2 "Run 'bwvault sync' and retry if the item changed recently."
    return 1
  }
  REPLY="$(print -rn -- "$inventory" | jq -cs --arg name "$item_name" '.[] | select(.name == $name)')"
}

_bwfile_content_stream() {
  local session="$1" id="$2"
  setopt localoptions pipefail
  BW_SESSION="$session" bw get item "$id" 2>/dev/null | jq -je '
    [.fields[]? | select(.name == "content" and .type == 1 and (.value | type == "string"))]
    | if length == 1 then .[0].value else error("missing or ambiguous content field") end
  '
}

_bwfile_content_matches() {
  local session="$1" id="$2" destination="$3"
  local -a stages
  setopt localoptions pipefail
  _bwfile_content_stream "$session" "$id" | cmp -s -- "$destination" -
  stages=(${pipestatus[@]})
  (( stages[1] == 0 )) || return 2
  (( stages[2] == 0 ))
}

_bwfile_save() {
  _bwfile_require_tools || return 1
  local source="" payload_source="" logical_name="" lifecycle=provision mode="" description="" force=0
  while (( $# > 0 )); do
    case "$1" in
      -n|--name) (( $# >= 2 )) || { print -u2 "Missing value for $1."; return 2; }; logical_name="$2"; shift 2 ;;
      --lifecycle) (( $# >= 2 )) || { print -u2 'Missing value for --lifecycle.'; return 2; }; lifecycle="$2"; shift 2 ;;
      --mode) (( $# >= 2 )) || { print -u2 'Missing value for --mode.'; return 2; }; mode="$2"; shift 2 ;;
      --description) (( $# >= 2 )) || { print -u2 'Missing value for --description.'; return 2; }; description="$2"; shift 2 ;;
      --force|--update) force=1; shift ;;
      --) shift ;;
      -*) print -u2 "Unknown bwfile save option: $1"; return 2 ;;
      *) [[ -z "$source" ]] || { print -u2 'bwfile save accepts exactly one path.'; return 2; }; source="$1"; shift ;;
    esac
  done
  [[ -n "$source" ]] || { print -u2 'Usage: bwfile save PATH [--name NAME] [--lifecycle provision|recovery] [--mode MODE] [--description TEXT] [--force]'; return 2; }
  [[ -f "$source" && -r "$source" ]] || { print -u2 "Source is not a readable regular file: $source"; return 1; }
  payload_source="${source:A}"
  [[ -f "$payload_source" && -r "$payload_source" ]] || { print -u2 "Symlink target is not a readable regular file: $source"; return 1; }
  _bwfile_text_file "$payload_source" || { print -u2 'bwfile v1 accepts only textual files without NUL bytes or invalid text encoding.'; return 1; }
  [[ "$lifecycle" == provision || "$lifecycle" == recovery ]] || { print -u2 "Invalid lifecycle: $lifecycle"; return 2; }
  [[ -n "$mode" ]] || mode="$(_bwfile_file_mode "$payload_source")" || { print -u2 "Unable to determine source permissions: $payload_source"; return 1; }
  [[ "$mode" == 0* ]] || mode="0$mode"
  _bwfile_valid_mode "$mode" || {
    print -u2 "Unsafe mode '$mode': only owner read/write and optional group read are allowed."
    print -u2 "Retry with '--mode 0600' to store a secure restore mode without changing the source file."
    return 1
  }

  local absolute configured item_name metadata session matches count id result
  absolute="${source:a}"
  configured="$absolute"
  [[ "$absolute" == "$HOME"/* ]] && configured="~/${absolute#$HOME/}"
  [[ -n "$logical_name" ]] || logical_name="${source:t}"
  logical_name="$(_bwfile_normalize_name "$logical_name")"
  item_name="$(_bwfile_item_name "$logical_name")" || { print -u2 'Invalid bwfile logical name.'; return 2; }
  metadata="$(_bwfile_metadata_yaml "$configured" "$mode" "$lifecycle" "$description")" || { print -u2 'Unable to create bwfile metadata.'; return 1; }
  _bwfile_parse_metadata "$item_name" "$metadata" || {
    print -u2 'Path or description contains unsupported metadata characters.'
    return 1
  }
  session="$(_bw_session)" || { print -u2 'Unable to unlock the Bitwarden CLI vault.'; return 1; }
  matches="$(BW_SESSION="$session" bw list items 2>/dev/null | jq -c --arg name "$item_name" '[.[] | select(.name == $name) | {id, name}]')" || { print -u2 'Unable to inspect existing Bitwarden items.'; return 1; }
  count="$(print -rn -- "$matches" | jq 'length')"
  (( count <= 1 )) || { print -u2 "Multiple Bitwarden items are named '$item_name'; resolve the ambiguity first."; return 1; }
  if (( count == 1 && ! force )); then
    print -u2 "Bitwarden item '$item_name' already exists. Use --force to update it."
    return 1
  fi

  setopt localoptions pipefail
  if (( count == 1 )); then
    id="$(print -rn -- "$matches" | jq -r '.[0].id')"
    if ! BW_SESSION="$session" bw get item "$id" 2>/dev/null \
      | jq -c --arg name "$item_name" --arg notes "$metadata" --rawfile content "$payload_source" '
          .name = $name | .type = 2 | .secureNote = {type: 0} | .notes = $notes
          | .fields = ([.fields[]? | select(.name != "content")] + [{name:"content", value:$content, type:1}])
          | del(.login, .card, .identity, .sshKey)
        ' | bw encode | BW_SESSION="$session" bw edit item "$id" >/dev/null 2>&1; then
      print -u2 "Unable to update Bitwarden item '$item_name'."
      return 1
    fi
  else
    if ! BW_SESSION="$session" bw get template item 2>/dev/null \
      | jq -c --arg name "$item_name" --arg notes "$metadata" --rawfile content "$payload_source" '
          .name = $name | .type = 2 | .secureNote = {type: 0} | .notes = $notes
          | .fields = [{name:"content", value:$content, type:1}]
          | del(.login, .card, .identity, .sshKey)
        ' | bw encode | BW_SESSION="$session" bw create item >/dev/null 2>&1; then
      print -u2 "Unable to create Bitwarden item '$item_name'."
      return 1
    fi
  fi
  print "Saved $item_name"
  print "Path: $configured"
  print "Mode: $mode"
  print "Lifecycle: $lifecycle"
  _bw_mutation_notice
}

_bwfile_materialize() {
  local session="$1" record="$2" force="$3" name id configured mode lifecycle destination parent temporary stages existed=0
  name="$(print -rn -- "$record" | jq -r '.name')"
  id="$(print -rn -- "$record" | jq -r '.id')"
  configured="$(print -rn -- "$record" | jq -r '.path')"
  mode="$(print -rn -- "$record" | jq -r '.mode')"
  lifecycle="$(print -rn -- "$record" | jq -r '.lifecycle')"
  if [[ "$(print -rn -- "$record" | jq -r '.valid')" != true ]]; then
    print -u2 "Invalid metadata: $name ($(print -rn -- "$record" | jq -r '.error'))"
    return 1
  fi
  _bwfile_valid_mode "$mode" || { print -u2 "Invalid or unsafe mode for $name."; return 1; }
  _bwfile_resolve_path "$configured"
  case $? in
    0) destination="$REPLY" ;;
    2) print -u2 "Refusing path with a symlink component for $name: $configured"; return 1 ;;
    *) print -u2 "Invalid destination path for $name: $configured"; return 1 ;;
  esac
  [[ ! -d "$destination" ]] || { print -u2 "Destination is a directory for $name: $configured"; return 1; }
  [[ ! -L "$destination" ]] || { print -u2 "Refusing symlink destination for $name: $configured"; return 1; }

  if [[ -e "$destination" ]]; then
    existed=1
    _bwfile_content_matches "$session" "$id" "$destination"
    local comparison=$?
    if (( comparison == 0 )); then
      local current_mode
      current_mode="$(_bwfile_file_mode "$destination")" || { print -u2 "Unable to read permissions for $name."; return 1; }
      if [[ "$current_mode" != "$mode" ]]; then
        chmod "$mode" -- "$destination" 2>/dev/null || { print -u2 "Unable to correct permissions for $name."; return 1; }
        print "Corrected mode: ${name#$BWFILE_PREFIX}  $configured  $mode"
      else
        print "Up to date: ${name#$BWFILE_PREFIX}  $configured"
      fi
      return 0
    elif (( comparison == 2 )); then
      print -u2 "Unable to retrieve content for $name."
      return 1
    elif (( ! force )); then
      print -u2 "Local file differs for ${name#$BWFILE_PREFIX}: $configured (use --force to replace it)"
      return 1
    fi
  fi

  parent="${destination:h}"
  ( umask 077; mkdir -p -- "$parent" ) 2>/dev/null || { print -u2 "Unable to create destination directory for $name."; return 1; }
  _bwfile_resolve_path "$configured" || { print -u2 "Destination became unsafe for $name."; return 1; }
  temporary="$(umask 077; mktemp "$parent/.bwfile.XXXXXXXX")" || { print -u2 "Unable to create a secure temporary file for $name."; return 1; }
  chmod 600 -- "$temporary" 2>/dev/null || { rm -f -- "$temporary"; print -u2 "Unable to secure temporary file for $name."; return 1; }
  setopt localoptions pipefail
  _bwfile_content_stream "$session" "$id" >| "$temporary"
  stages=(${pipestatus[@]})
  if ! _bw_pipefail "${stages[@]}"; then
    rm -f -- "$temporary"
    print -u2 "Unable to retrieve content for $name."
    return 1
  fi
  chmod "$mode" -- "$temporary" 2>/dev/null || { rm -f -- "$temporary"; print -u2 "Unable to apply mode for $name."; return 1; }
  [[ ! -d "$destination" && ! -L "$destination" ]] || { rm -f -- "$temporary"; print -u2 "Destination became unsafe for $name."; return 1; }
  if (( ! force && ! existed )) && [[ -e "$destination" ]]; then
    rm -f -- "$temporary"
    print -u2 "Destination appeared during restore for $name; refusing to overwrite it."
    return 1
  fi
  mv -f -- "$temporary" "$destination" 2>/dev/null || { rm -f -- "$temporary"; print -u2 "Unable to atomically install $name."; return 1; }
  print "Loaded: ${name#$BWFILE_PREFIX}  $configured  $mode  $lifecycle"
}

_bwfile_load() {
  _bwfile_require_tools || return 1
  local force=0 all=0 lifecycle="" requested=""
  while (( $# > 0 )); do
    case "$1" in
      --force) force=1; shift ;;
      --all) all=1; shift ;;
      --lifecycle) (( $# >= 2 )) || { print -u2 'Missing value for --lifecycle.'; return 2; }; lifecycle="$2"; shift 2 ;;
      --) shift ;;
      -*) print -u2 "Unknown bwfile load option: $1"; return 2 ;;
      *) [[ -z "$requested" ]] || { print -u2 'bwfile load accepts one name or a bulk option.'; return 2; }; requested="$1"; shift ;;
    esac
  done
  (( all + (${#lifecycle} > 0) + (${#requested} > 0) == 1 )) || { print -u2 'Usage: bwfile load NAME [--force] | --all [--force] | --lifecycle provision|recovery [--force]'; return 2; }
  [[ -z "$lifecycle" || "$lifecycle" == provision || "$lifecycle" == recovery ]] || { print -u2 "Invalid lifecycle: $lifecycle"; return 2; }
  (( all )) && lifecycle=provision
  local session inventory record failed=0 succeeded=0 skipped=0
  session="$(_bw_session)" || { print -u2 'Unable to unlock the Bitwarden CLI vault.'; return 1; }
  if [[ -n "$requested" ]]; then
    _bwfile_find "$session" "$requested" || return 1
    inventory="$REPLY"
  else
    inventory="$(_bwfile_inventory "$session")" || return 1
    inventory="$(print -rn -- "$inventory" | jq -cs --arg lifecycle "$lifecycle" '.[] | select(.valid == false or .lifecycle == $lifecycle)')"
  fi
  [[ -n "$inventory" ]] || { print 'No matching bwfile items.'; return 0; }
  while IFS= read -r record; do
    if _bwfile_materialize "$session" "$record" "$force"; then (( ++succeeded )); else (( ++failed )); fi
  done <<< "$inventory"
  if [[ -z "$requested" ]]; then
    print "Summary: $succeeded succeeded, $failed failed"
  fi
  (( failed == 0 ))
}

_bwfile_list() {
  _bwfile_require_tools || return 1
  local search="" session inventory record name lifecycle listed_path
  while (( $# > 0 )); do
    case "$1" in
      -s|--search) (( $# >= 2 )) || { print -u2 "Missing value for $1."; return 2; }; search="$2"; shift 2 ;;
      *) print -u2 'Usage: bwfile list [--search TEXT]'; return 2 ;;
    esac
  done
  session="$(_bw_session)" || return 1
  inventory="$(_bwfile_inventory "$session")" || return 1
  print -r -- $'NAME\tLIFECYCLE\tPATH'
  [[ -n "$inventory" ]] || return 0
  while IFS= read -r record; do
    name="$(print -rn -- "$record" | jq -r '.name')"
    [[ -z "$search" || "${(L)name}" == *"${(L)search}"* ]] || continue
    if [[ "$(print -rn -- "$record" | jq -r '.valid')" == true ]]; then
      lifecycle="$(print -rn -- "$record" | jq -r '.lifecycle')"
      listed_path="$(print -rn -- "$record" | jq -r '.path')"
    else
      lifecycle='invalid'
      listed_path="$(print -rn -- "$record" | jq -r '.error')"
    fi
    print -r -- "${name#$BWFILE_PREFIX}"$'\t'"$lifecycle"$'\t'"$listed_path"
  done <<< "$inventory" | column -t -s $'\t'
}

_bwfile_local_state() {
  local session="$1" record="$2" name id configured mode destination current_mode
  name="$(print -rn -- "$record" | jq -r '.name')"
  id="$(print -rn -- "$record" | jq -r '.id')"
  configured="$(print -rn -- "$record" | jq -r '.path')"
  mode="$(print -rn -- "$record" | jq -r '.mode')"
  _bwfile_resolve_path "$configured" || { REPLY='unsafe path'; return 1; }
  destination="$REPLY"
  [[ ! -d "$destination" && ! -L "$destination" ]] || { REPLY='unsafe destination'; return 1; }
  [[ -e "$destination" ]] || { REPLY='missing'; return 0; }
  [[ -r "$destination" ]] || { REPLY='inaccessible'; return 1; }
  _bwfile_content_matches "$session" "$id" "$destination"
  case $? in
    0) ;;
    1) REPLY='content differs'; return 0 ;;
    *) REPLY='vault content unavailable'; return 1 ;;
  esac
  current_mode="$(_bwfile_file_mode "$destination")" || { REPLY='inaccessible'; return 1; }
  [[ "$current_mode" == "$mode" ]] && REPLY='present and matches' || REPLY="wrong permissions ($current_mode, expected $mode)"
}

_bwfile_show() {
  _bwfile_require_tools || return 1
  (( $# == 1 )) || { print -u2 'Usage: bwfile show NAME'; return 2; }
  local session record state
  session="$(_bw_session)" || return 1
  _bwfile_find "$session" "$1" || return 1
  record="$REPLY"
  [[ "$(print -rn -- "$record" | jq -r '.valid')" == true ]] || { print -u2 "Invalid metadata: $(print -rn -- "$record" | jq -r '.error')"; return 1; }
  _bwfile_local_state "$session" "$record"; state="$REPLY"
  print "Name: $(print -rn -- "$record" | jq -r '.name')"
  print "Version: $(print -rn -- "$record" | jq -r '.version')"
  print "Path: $(print -rn -- "$record" | jq -r '.path')"
  print "Mode: $(print -rn -- "$record" | jq -r '.mode')"
  print "Lifecycle: $(print -rn -- "$record" | jq -r '.lifecycle')"
  [[ -z "$(print -rn -- "$record" | jq -r '.description')" ]] || print "Description: $(print -rn -- "$record" | jq -r '.description')"
  print "Local state: $state"
}

_bwfile_status() {
  _bwfile_require_tools || return 1
  (( $# == 0 )) || { print -u2 'Usage: bwfile status'; return 2; }
  local session inventory record name state failed=0
  session="$(_bw_session)" || return 1
  inventory="$(_bwfile_inventory "$session")" || return 1
  [[ -n "$inventory" ]] || { print 'No bwfile items.'; return 0; }
  while IFS= read -r record; do
    name="$(print -rn -- "$record" | jq -r '.name')"
    if [[ "$(print -rn -- "$record" | jq -r '.valid')" != true ]]; then
      print "! ${name#$BWFILE_PREFIX}: $(print -rn -- "$record" | jq -r '.error')"
      (( ++failed )); continue
    fi
    _bwfile_local_state "$session" "$record"; state="$REPLY"
    [[ "$state" == 'present and matches' ]] || (( ++failed ))
    if [[ "$(print -rn -- "$record" | jq -r '.lifecycle')" == recovery ]]; then
      print "${name#$BWFILE_PREFIX}: recovery-only; $state"
    else
      print "${name#$BWFILE_PREFIX}: $state"
    fi
    print "  $(print -rn -- "$record" | jq -r '.path')  $(print -rn -- "$record" | jq -r '.mode')  $(print -rn -- "$record" | jq -r '.lifecycle')"
  done <<< "$inventory"
  (( failed == 0 ))
}

_bwfile_remove() {
  _bwfile_require_tools || return 1
  local force=0 requested=""
  while (( $# > 0 )); do
    case "$1" in
      --force) force=1; shift ;;
      -*) print -u2 "Unknown bwfile remove option: $1"; return 2 ;;
      *) [[ -z "$requested" ]] || { print -u2 'Usage: bwfile remove NAME [--force]'; return 2; }; requested="$1"; shift ;;
    esac
  done
  [[ -n "$requested" ]] || { print -u2 'Usage: bwfile remove NAME [--force]'; return 2; }
  local session record name id answer
  session="$(_bw_session)" || return 1
  _bwfile_find "$session" "$requested" || return 1
  record="$REPLY" name="$(print -rn -- "$record" | jq -r '.name')" id="$(print -rn -- "$record" | jq -r '.id')"
  if (( ! force )); then
    [[ -t 0 ]] || { print -u2 'Confirmation requires a terminal; use --force after verifying the item name.'; return 1; }
    print -n "Remove Bitwarden item '$name'? [y/N] "
    read -r answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { print 'Cancelled.'; return 1; }
  fi
  BW_SESSION="$session" bw delete item "$id" >/dev/null 2>&1 || { print -u2 "Unable to remove Bitwarden item '$name'."; return 1; }
  print "Removed Bitwarden item: $name"
  print 'The local file was not deleted.'
  _bw_mutation_notice
}

_bwfile_help() {
  print -r -- 'Usage: bwfile <command> [arguments]

Commands:
  save PATH              store a textual local file in a hidden content field
  load NAME              securely restore one managed file
  load --all             restore provision items only
  load --lifecycle TYPE  restore provision or recovery items explicitly
  list                    list logical names and non-secret metadata
  show NAME               show metadata and local state, never content
  status                  compare managed files with vault content
  remove NAME             remove only the Bitwarden item after confirmation
  help                    show this help

Reads never sync automatically. Recovery items are never included by --all.
Paths must be absolute or begin with ~/. Save follows source symlinks; load refuses symlinks.
Version 1 supports textual files only and owner read/write with optional group read.'
}

bwfile() {
  local command_name="${1:-help}"
  (( $# > 0 )) && shift
  case "$command_name" in
    save) _bwfile_save "$@" ;;
    load) _bwfile_load "$@" ;;
    list) _bwfile_list "$@" ;;
    show) _bwfile_show "$@" ;;
    status) _bwfile_status "$@" ;;
    remove) _bwfile_remove "$@" ;;
    help|-h|--help) _bwfile_help ;;
    *) print -u2 "Unknown bwfile command: $command_name"; print -u2 "Run 'bwfile help' to see available commands."; return 2 ;;
  esac
}

# -------------------------------------------------------------------
# Bitwarden SSH keys and the native OpenSSH agent
# -------------------------------------------------------------------

BW_SSH_TTL="${BW_SSH_TTL:-}"

_bwssh_require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 "bwssh requires '$1'."
    return 1
  fi
}

_bwssh_require_vault_tools() {
  _bwssh_require bw && _bwssh_require jq
}

_bwssh_agent_list() {
  [[ -n "${SSH_AUTH_SOCK:-}" ]] || return 2
  command ssh-add -l -E sha256 2>/dev/null
  local exit_code=$?
  (( exit_code == 1 )) && return 0
  return $exit_code
}

_bwssh_require_agent() {
  _bwssh_require ssh-add || return 1
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    print -u2 'No SSH agent is configured: SSH_AUTH_SOCK is empty.'
    return 1
  fi
  _bwssh_agent_list >/dev/null || {
    print -u2 'Unable to reach the SSH agent through SSH_AUTH_SOCK.'
    return 1
  }
}

_bwssh_loaded_fingerprints() {
  local listing line
  local -a fields
  listing="$(_bwssh_agent_list)" || return $?
  reply=()
  for line in ${(f)listing}; do
    fields=(${(z)line})
    (( ${#fields} >= 2 )) && reply+=("${fields[2]}")
  done
}

_bwssh_is_loaded() {
  local fingerprint="$1" loaded
  for loaded in "${reply[@]}"; do
    [[ "$loaded" == "$fingerprint" ]] && return 0
  done
  return 1
}

_bwssh_metadata() {
  local session="$1" search="${2:-}"
  setopt localoptions pipefail
  BW_SESSION="$session" bw list items 2>/dev/null \
    | jq -er --arg search "$search" '
        .[]
        | select(.type == 5 and (.sshKey? | type == "object"))
        | select($search == "" or (.name | test($search; "i")))
        | [
            .id,
            (.name | gsub("[\\t\\r\\n]"; " ")),
            (.sshKey.keyFingerprint // .sshKey.fingerprint // ""),
            ((.sshKey.publicKey // "") | split(" ")[0])
          ]
        | @tsv
      '
}

_bwssh_resolve_name() {
  local session="$1" requested_name="$2"
  setopt localoptions pipefail
  REPLY="$(
    BW_SESSION="$session" bw list items 2>/dev/null \
      | jq -cer --arg name "$requested_name" '
          [.[] | select(.type == 5 and .name == $name)]
          | if length == 1 then
              .[0] | {
                id,
                name,
                fingerprint: (.sshKey.keyFingerprint // .sshKey.fingerprint // ""),
                publicKey: (.sshKey.publicKey // "")
              }
            else error("SSH key name is missing or ambiguous") end
        '
  )" || {
    print -u2 "Unable to find a unique Bitwarden SSH-key item named '$requested_name'."
    print -u2 "Run 'bwvault sync' and retry if the item was added recently."
    return 1
  }
}

_bwssh_select_items() {
  local session="$1" candidates selected line
  _bwssh_require fzf || return 1
  candidates="$(_bwssh_metadata "$session")" || {
    print -u2 'Unable to list Bitwarden SSH-key items from the current vault data.'
    print -u2 "Run 'bwvault sync' and retry if keys were added recently."
    return 1
  }
  [[ -n "$candidates" ]] || {
    print -u2 'No SSH-key items were found in the current Bitwarden vault data.'
    return 1
  }
  selected="$(
    print -r -- "$candidates" \
      | fzf --multi --delimiter=$'\t' --with-nth=2,3,4 \
            --header='Select SSH keys (private keys are never displayed)'
  )"
  if [[ $? -ne 0 || -z "$selected" ]]; then
    return 130
  fi
  reply=()
  for line in ${(f)selected}; do
    reply+=("${line%%$'\t'*}")
  done
}

_bwssh_source_items() {
  local session="$1" requested_name
  shift
  reply=()
  if (( $# == 0 )); then
    _bwssh_select_items "$session" || return $?
    return
  fi
  for requested_name in "$@"; do
    _bwssh_resolve_name "$session" "$requested_name" || return 1
    reply+=("$(jq -r '.id' <<< "$REPLY")")
  done
}

_bwssh_fingerprint_public_key() {
  local public_key="$1" details
  details="$(print -r -- "$public_key" | ssh-keygen -lf - -E sha256 2>/dev/null)" || return 1
  local -a fields
  fields=(${(z)details})
  (( ${#fields} >= 2 )) || return 1
  REPLY="${fields[2]}"
}

_bwssh_filter_create_error() {
  local line redacted=0
  while IFS= read -r line; do
    if [[ "$line" == *privateKey* || "$line" == *'PRIVATE KEY'* ]]; then
      (( redacted )) || print -u2 'Bitwarden returned an error containing private-key data; details were redacted.'
      redacted=1
    else
      print -u2 -r -- "$line"
    fi
  done
}

_bwssh_import() {
  _bwssh_require_vault_tools || return 1
  _bwssh_require ssh-keygen || return 1
  local private_path="" name="" public_path="" force=0
  while (( $# > 0 )); do
    case "$1" in
      -n|--name)
        (( $# >= 2 )) || { print -u2 "Missing value for $1."; return 2; }
        name="$2"
        shift 2
        ;;
      --public-key)
        (( $# >= 2 )) || { print -u2 'Missing value for --public-key.'; return 2; }
        public_path="$2"
        shift 2
        ;;
      --force) force=1; shift ;;
      --) shift ;;
      -*) print -u2 "Unknown bwssh import option: $1"; return 2 ;;
      *)
        [[ -z "$private_path" ]] || {
          print -u2 'bwssh import accepts exactly one private-key path.'
          return 2
        }
        private_path="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$private_path" ]]; then
    print -u2 'Usage: bwssh import PRIVATE_KEY [--name NAME] [--public-key PATH] [--force]'
    return 2
  fi

  local public_key key_type fingerprint session duplicate created write_public=1
  [[ -f "$private_path" && -r "$private_path" ]] || {
    print -u2 "Private key is not a readable regular file: $private_path"
    return 1
  }
  [[ -n "$name" ]] || name="${private_path:t}"
  public_key="$(ssh-keygen -y -f "$private_path")" || {
    print -u2 "The input is not a supported private SSH key: $private_path"
    return 1
  }
  key_type="${public_key%% *}"
  case "$key_type" in
    ssh-ed25519|ssh-rsa) ;;
    *)
      print -u2 "Unsupported SSH key type: $key_type (Bitwarden supports Ed25519 and RSA)."
      return 1
      ;;
  esac
  _bwssh_fingerprint_public_key "$public_key" || {
    print -u2 'Unable to derive the public-key fingerprint.'
    return 1
  }
  fingerprint="$REPLY"
  setopt localoptions pipefail
  session="$(_bw_session)" || {
    print -u2 'Unable to unlock the Bitwarden CLI vault.'
    return 1
  }
  duplicate="$(
    BW_SESSION="$session" bw list items 2>/dev/null \
      | jq -r --arg fingerprint "$fingerprint" \
          'any(.[]; .type == 5 and (.sshKey.keyFingerprint // .sshKey.fingerprint) == $fingerprint)'
  )" || {
    print -u2 'Unable to inspect existing Bitwarden SSH-key fingerprints.'
    return 1
  }
  if [[ "$duplicate" == true && force -eq 0 ]]; then
    print -u2 "An SSH-key item with fingerprint $fingerprint already exists."
    print -u2 'Use --force only after verifying that another item is intentional.'
    return 1
  fi
  if [[ -n "$public_path" && "${public_path:A}" == "${private_path:A}" ]]; then
    print -u2 'The public-key output path must differ from the private-key input path.'
    return 1
  fi
  if [[ -n "$public_path" && -e "$public_path" ]]; then
    local existing_public existing_fingerprint=""
    existing_public="$(<"$public_path")" 2>/dev/null || true
    if [[ -n "$existing_public" ]]; then
      _bwssh_fingerprint_public_key "$existing_public" && existing_fingerprint="$REPLY"
    fi
    if [[ "$existing_fingerprint" == "$fingerprint" ]]; then
      write_public=0
    elif (( ! force )); then
      print -u2 "Public-key output exists but does not match the private key: $public_path"
      print -u2 'Choose another output path or use --force to overwrite it after import.'
      return 1
    fi
  fi

  if ! created="$(
    BW_SESSION="$session" bw get template item 2>/dev/null \
      | jq -c --arg name "$name" --rawfile privateKey "$private_path" \
          --arg publicKey "$public_key" --arg fingerprint "$fingerprint" '
          .type = 5
          | .name = $name
          | .sshKey = {
              privateKey: $privateKey,
              publicKey: $publicKey,
              keyFingerprint: $fingerprint
            }
          | del(.login, .secureNote, .card, .identity)
        ' \
      | bw encode \
      | BW_SESSION="$session" bw create item 2> >(_bwssh_filter_create_error) \
      | jq -er '[.name, (.sshKey.keyFingerprint // .sshKey.fingerprint)] | @tsv'
  )"; then
    print -u2 'Unable to create the Bitwarden SSH-key item.'
    return 1
  fi
  if [[ -n "$public_path" && write_public -eq 1 ]]; then
    print -r -- "$public_key" >| "$public_path" || {
      print -u2 "The Bitwarden item was created, but the public key could not be written: $public_path"
      return 1
    }
    print "Public key written: $public_path"
  elif [[ -n "$public_path" ]]; then
    print "Public key already exists and matches: $public_path"
  fi
  print "Imported: ${created%%$'\t'*}  ${created#*$'\t'}"
  _bw_mutation_notice
}

_bwssh_load() {
  _bwssh_require_vault_tools || return 1
  _bwssh_require_agent || return 1
  local -a ttlarg names ids loaded
  zparseopts -D -E -F -K -- -ttl:=ttlarg || return 2
  names=("$@")
  local ttl="${ttlarg[-1]:-${BW_SSH_TTL:-}}" session id item name fingerprint
  local -a add_args stages
  [[ -n "$ttl" ]] && add_args=(-t "$ttl")
  session="$(_bw_session)" || {
    print -u2 'Unable to unlock the Bitwarden CLI vault.'
    return 1
  }
  _bwssh_source_items "$session" "${names[@]}" || return $?
  ids=("${reply[@]}")
  _bwssh_loaded_fingerprints || return 1
  loaded=("${reply[@]}")
  reply=("${loaded[@]}")
  local count=0 failed=0
  for id in "${ids[@]}"; do
    item="$(BW_SESSION="$session" bw get item "$id" 2>/dev/null | jq -cer \
      '{name, fingerprint: (.sshKey.keyFingerprint // .sshKey.fingerprint)}')" || {
      print -u2 "Unable to read Bitwarden SSH-key metadata for item $id."
      (( ++failed ))
      continue
    }
    name="$(jq -r '.name' <<< "$item")"
    fingerprint="$(jq -r '.fingerprint // ""' <<< "$item")"
    if [[ -n "$fingerprint" ]] && _bwssh_is_loaded "$fingerprint"; then
      print "Already loaded: $name  $fingerprint"
      continue
    fi
    setopt localoptions pipefail
    BW_SESSION="$session" bw get item "$id" 2>/dev/null \
      | jq -er '.sshKey.privateKey | select(length > 0)' \
      | ssh-add "${add_args[@]}" -
    stages=("${pipestatus[@]}")
    if ! _bw_pipefail "${stages[@]}"; then
      print -u2 "Unable to load SSH key: $name"
      (( ++failed ))
      continue
    fi
    print "Loaded: $name${fingerprint:+  $fingerprint}"
    (( ++count ))
  done
  (( count > 0 || failed == 0 )) && (( failed == 0 ))
}

_bwssh_unload() {
  _bwssh_require_agent || return 1
  local -a allarg names ids loaded
  zparseopts -D -E -F -K -- -all=allarg || return 2
  if (( ${#allarg} )); then
    (( $# == 0 )) || {
      print -u2 'bwssh unload --all does not accept key names.'
      return 2
    }
    ssh-add -D
    return $?
  fi
  _bwssh_require_vault_tools || return 1
  names=("$@")
  local session id item name fingerprint public_key
  session="$(_bw_session)" || {
    print -u2 'Unable to unlock the Bitwarden CLI vault.'
    return 1
  }
  _bwssh_source_items "$session" "${names[@]}" || return $?
  ids=("${reply[@]}")
  _bwssh_loaded_fingerprints || return 1
  loaded=("${reply[@]}")
  reply=("${loaded[@]}")
  local count=0 failed=0
  for id in "${ids[@]}"; do
    item="$(BW_SESSION="$session" bw get item "$id" 2>/dev/null | jq -cer \
      '{name, fingerprint: (.sshKey.keyFingerprint // .sshKey.fingerprint), publicKey: .sshKey.publicKey}')" || {
      print -u2 "Unable to read Bitwarden SSH-key metadata for item $id."
      (( ++failed ))
      continue
    }
    name="$(jq -r '.name' <<< "$item")"
    fingerprint="$(jq -r '.fingerprint // ""' <<< "$item")"
    public_key="$(jq -r '.publicKey // ""' <<< "$item")"
    if [[ -n "$fingerprint" ]] && ! _bwssh_is_loaded "$fingerprint"; then
      print "Not loaded: $name  $fingerprint"
      continue
    fi
    if [[ -z "$public_key" ]] || ! print -r -- "$public_key" | ssh-add -d -; then
      print -u2 "Unable to unload '$name' by public key. This OpenSSH may not support 'ssh-add -d -'."
      print -u2 "Use 'bwssh unload --all' or 'ssh-add -d /path/to/public-key'."
      (( ++failed ))
      continue
    fi
    print "Unloaded: $name${fingerprint:+  $fingerprint}"
    (( ++count ))
  done
  (( count > 0 || failed == 0 )) && (( failed == 0 ))
}

_bwssh_list() {
  _bwssh_require_vault_tools || return 1
  local search=""
  while (( $# > 0 )); do
    case "$1" in
      -s|--search)
        (( $# >= 2 )) || { print -u2 "Missing value for $1."; return 2; }
        search="$2"
        shift 2
        ;;
      --) shift ;;
      *) print -u2 'Usage: bwssh list [--search TEXT]'; return 2 ;;
    esac
  done
  local session metadata line marker id name fingerprint key_type
  session="$(_bw_session)" || {
    print -u2 'Unable to unlock the Bitwarden CLI vault.'
    return 1
  }
  metadata="$(_bwssh_metadata "$session" "$search")" || {
    print -u2 'Unable to list Bitwarden SSH-key items.'
    return 1
  }
  [[ -n "$metadata" ]] || {
    print -u2 'No matching Bitwarden SSH-key items were found.'
    return 1
  }
  _bwssh_loaded_fingerprints || reply=()
  print -r -- $'loaded\tname\tfingerprint\ttype'
  for line in ${(f)metadata}; do
    IFS=$'\t' read -r id name fingerprint key_type <<< "$line"
    marker='-'
    [[ -n "$fingerprint" ]] && _bwssh_is_loaded "$fingerprint" && marker='yes'
    print -r -- "$marker"$'\t'"$name"$'\t'"$fingerprint"$'\t'"$key_type"
  done | column -t -s $'\t'
}

_bwssh_status() {
  _bwssh_require bw || return 1
  _bwssh_require jq || return 1
  local vault_status agent_listing session metadata line id name fingerprint key_type
  vault_status="$(bw status 2>/dev/null | jq -r '.status // "unavailable"')" || vault_status=unavailable
  print "Vault: $vault_status"
  if agent_listing="$(_bwssh_agent_list)"; then
    print 'SSH agent: available'
  else
    print 'SSH agent: unavailable'
  fi
  if [[ -z "${BW_SESSION:-}" ]]; then
    print 'Stored keys: unavailable without an existing BW_SESSION (status does not unlock the vault)'
    [[ "$agent_listing" == '' ]] || print -r -- "$agent_listing"
    return 0
  fi
  session="$BW_SESSION"
  metadata="$(_bwssh_metadata "$session")" || {
    print 'Stored keys: unavailable with the current BW_SESSION'
    return 1
  }
  _bwssh_loaded_fingerprints || reply=()
  print 'Loaded keys:'
  local loaded_count=0 unloaded_count=0
  for line in ${(f)metadata}; do
    IFS=$'\t' read -r id name fingerprint key_type <<< "$line"
    if [[ -n "$fingerprint" ]] && _bwssh_is_loaded "$fingerprint"; then
      print "  loaded  $name  $fingerprint"
      (( ++loaded_count ))
    fi
  done
  (( loaded_count > 0 )) || print '  <none>'
  print 'Stored but unloaded:'
  for line in ${(f)metadata}; do
    IFS=$'\t' read -r id name fingerprint key_type <<< "$line"
    if [[ -z "$fingerprint" ]] || ! _bwssh_is_loaded "$fingerprint"; then
      print "  -  $name  $fingerprint"
      (( ++unloaded_count ))
    fi
  done
  (( unloaded_count > 0 )) || print '  <none>'
}

_bwssh_help() {
  case "${1:-}" in
    import) print -r -- 'Usage: bwssh import PRIVATE_KEY [--name NAME] [--public-key PATH] [--force]
Validate an existing Ed25519 or RSA private key, derive its public key and SHA-256 fingerprint,
and create a native Bitwarden SSH-key item. --public-key is an optional output path for the
derived public key, not a second input. The source private key is not deleted.' ;;
    load) print -r -- 'Usage: bwssh load [--ttl DURATION] [NAME ...]
Load selected Bitwarden private keys into the native OpenSSH agent over stdin.
With no names, fzf provides multi-selection. BW_SSH_TTL supplies an optional default lifetime.' ;;
    unload) print -r -- 'Usage: bwssh unload [NAME ...]
       bwssh unload --all
Remove selected identities by streaming public keys to ssh-add -d -, or remove every identity.
Bitwarden items are never changed.' ;;
    list) print -r -- 'Usage: bwssh list [--search TEXT]
List non-secret SSH-key metadata and whether each fingerprint is loaded in the current agent.' ;;
    status) print -r -- 'Usage: bwssh status
Show Bitwarden CLI and native agent availability without unlocking the vault.
Stored-key details are included only when BW_SESSION is already set.' ;;
    *) print -r -- 'Usage: bwssh <command> [arguments]

Commands:
  import   import an existing private key as a native Bitwarden SSH-key item
  load     load one or more keys into the native OpenSSH agent
  unload   remove selected or all identities from the agent
  list     list safe vault metadata and loaded state
  status   show vault and agent availability without unlocking
  help     show this help or help for a command

Reads never sync automatically. Run `bwvault sync` explicitly when vault data may be stale.' ;;
  esac
}

bwssh() {
  local command_name="${1:-help}"
  (( $# > 0 )) && shift
  case "$command_name" in
    import) _bwssh_import "$@" ;;
    load) _bwssh_load "$@" ;;
    unload) _bwssh_unload "$@" ;;
    list) _bwssh_list "$@" ;;
    status) _bwssh_status "$@" ;;
    help|-h|--help) _bwssh_help "${1:-}" ;;
    *)
      print -u2 "Unknown bwssh command: $command_name"
      print -u2 "Run 'bwssh help' to see available commands."
      return 2
      ;;
  esac
}

_bw_group_help() {
  case "$1" in
    vault)
      print -r -- 'Usage: bwvault <command>

Commands:
  unlock   unlock the vault and start bw serve when needed
  lock     lock the vault
  status   show vault lock status
  sync     explicitly synchronize the vault
  help     show this help'
      ;;
    item)
      print -r -- 'Usage: bwitem <command> [arguments]

Commands:
  password       select and copy a login password
  username       select and copy a login username
  credentials    interactively copy username, then password
  field          select a custom field value
  json           select and print an item as JSON
  search         advanced TSV/jq/fzf search
  generate       generate a secure password
  create login   create a login item
  edit TYPE      edit json, name, username, password, or field
  add field      add a custom field
  help           show this help'
      ;;
    note)
      print -r -- 'Usage: bwnote <command> [arguments]

Commands:
  get      select a secure note value
  create   create a secure note
  edit     edit a secure note value
  yaml     edit a note as structured YAML using $EDITOR
  help     show this help'
      ;;
  esac
}

_bw_mutation_notice() {
  print -u2 "Change sent to Bitwarden. If a later lookup is stale, run 'bwvault sync'."
}

bwvault() {
  local command_name="${1:-help}"
  (( $# > 0 )) && shift

  case "$command_name" in
    unlock) bw_unlock "$@" ;;
    lock) bw_lock "$@" ;;
    status) bw_serve && bw_status "$@" ;;
    sync) bw_serve && bw_sync "$@" ;;
    help|-h|--help) _bw_group_help vault ;;
    *)
      print -u2 "Unknown bwvault command: $command_name"
      print -u2 "Run 'bwvault help' to see available commands."
      return 2
      ;;
  esac
}

_bwitem_edit() {
  local edit_type="${1:-}"
  (( $# > 0 )) && shift

  case "$edit_type" in
    json) bw_json_edit "$@" && _bw_mutation_notice ;;
    name) bw_edit_name "$@" && _bw_mutation_notice ;;
    username) bw_edit_username "$@" && _bw_mutation_notice ;;
    password) bw_edit_password "$@" && _bw_mutation_notice ;;
    field) bw_edit_field "$@" && _bw_mutation_notice ;;
    *)
      print -u2 'Usage: bwitem edit <json|name|username|password|field> [arguments]'
      return 2
      ;;
  esac
}

_bwitem_generate() {
  local generate_type=secure
  if (( $# > 0 )); then
    if [[ "$1" == -* ]]; then
      generate_type=custom
    else
      generate_type="$1"
      shift
    fi
  fi

  case "$generate_type" in
    secure) bw_generate -ulns --length 21 "$@" ;;
    alphanumeric) bw_generate -uln --length 21 "$@" ;;
    custom) bw_generate "$@" ;;
    *)
      print -u2 'Usage: bwitem generate [secure|alphanumeric] [options]'
      return 2
      ;;
  esac
}

bwitem() {
  local command_name="${1:-help}" nested=""
  (( $# > 0 )) && shift

  case "$command_name" in
    password) bw_tsv -l -c .name -c .login.username -O .login.password "$@" ;;
    username) bw_tsv -l -c .name -o .login.username "$@" ;;
    credentials) bw_user_pass "$@" ;;
    field) bw_field "$@" ;;
    json) bw_unlock && bw_tsv -p -r -O . -c .name "$@" ;;
    search) bw_tsv "$@" ;;
    generate) _bwitem_generate "$@" ;;
    create)
      nested="${1:-}"
      (( $# > 0 )) && shift
      if [[ "$nested" == login ]]; then
        bw_create_login "$@" && _bw_mutation_notice
      else
        print -u2 'Usage: bwitem create login [arguments]'
        return 2
      fi
      ;;
    edit) _bwitem_edit "$@" ;;
    add)
      nested="${1:-}"
      (( $# > 0 )) && shift
      if [[ "$nested" == field ]]; then
        bw_add_field "$@" && _bw_mutation_notice
      else
        print -u2 'Usage: bwitem add field [arguments]'
        return 2
      fi
      ;;
    help|-h|--help) _bw_group_help item ;;
    *)
      print -u2 "Unknown bwitem command: $command_name"
      print -u2 "Run 'bwitem help' to see available commands."
      return 2
      ;;
  esac
}

bwnote() {
  local command_name="${1:-help}"
  (( $# > 0 )) && shift

  case "$command_name" in
    get) bw_tsv -n -c .name -o .notes "$@" ;;
    create) bw_create_note "$@" && _bw_mutation_notice ;;
    edit) bw_edit_note "$@" && _bw_mutation_notice ;;
    yaml) bw_notes_field_edit_as_yaml "$@" && _bw_mutation_notice ;;
    help|-h|--help) _bw_group_help note ;;
    *)
      print -u2 "Unknown bwnote command: $command_name"
      print -u2 "Run 'bwnote help' to see available commands."
      return 2
      ;;
  esac
}

_bwdoctor_version() {
  local command_name="$1" output
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 "missing: $command_name"
    return 1
  fi
  if ! output="$(command "$command_name" --version 2>/dev/null)"; then
    print -u2 "not working: $command_name --version"
    return 1
  fi
  print "ok: $command_name${output:+ (${output%%$'\n'*})}"
}

_bwdoctor_clipboard() {
  local provider
  for provider in pbcopy wl-copy xclip xsel clip.exe; do
    if command -v "$provider" >/dev/null 2>&1; then
      print "ok: clipboard ($provider)"
      return 0
    fi
  done
  if (( $+functions[clipcopy] )); then
    print 'ok: clipboard (clipcopy)'
    return 0
  fi
  print -u2 'missing: clipboard provider (pbcopy, wl-copy, xclip, xsel, or clip.exe)'
  return 1
}

bwdoctor() {
  local failed=0 command_name
  for command_name in bw jq fzf curl; do
    _bwdoctor_version "$command_name" || (( ++failed ))
  done
  for command_name in column pgrep mktemp; do
    if command -v "$command_name" >/dev/null 2>&1; then
      print "ok: $command_name"
    else
      print -u2 "missing: $command_name"
      (( ++failed ))
    fi
  done
  _bwdoctor_clipboard || (( ++failed ))

  command -v yq >/dev/null 2>&1 && print 'optional: yq available' || print 'optional: yq missing (required for bwnote yaml and bwfile)'
  command -v ssh-add >/dev/null 2>&1 && print 'optional: ssh-add available' || print 'optional: ssh-add missing (required only for bwssh)'
  command -v ssh-keygen >/dev/null 2>&1 && print 'optional: ssh-keygen available' || print 'optional: ssh-keygen missing (required only for bwssh import)'
  if [[ -x "$BWENV_KEYRING_BIN" ]] && BWENV_KEYRING_SERVICE="$BWENV_KEYRING_SERVICE" "$BWENV_KEYRING_BIN" status >/dev/null 2>&1; then
    print 'optional: Python keyring backend available'
  else
    print 'optional: Python keyring backend unavailable (required only for bwenv store/load/remove)'
  fi

  (( failed == 0 ))
}

# Remove aliases created by earlier plugin versions when reloading in-place.
unalias bwjs bwnfey bwjse bwls bwtsv bwst bwsn bwul bwlk bwn bwus bwpw bwno \
        bwfl bwup bwne bwuse bwpwe bwnoe bwfle bwfla bwg bwgs bwlc bwnc \
        bwexp bwsync kcexp kcunset kcglobal kcunglobal 2>/dev/null || true
