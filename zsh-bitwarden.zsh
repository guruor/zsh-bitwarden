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
  zparseopts -D -F -K -- \
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

  command -v yq >/dev/null 2>&1 && print 'optional: yq available' || print 'optional: yq missing (required only for bwnote yaml)'
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
