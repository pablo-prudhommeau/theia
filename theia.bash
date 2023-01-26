#!/bin/bash

# initialize global variables
SCRIPT_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
DUPLICITY_PASSPHRASE_FILE_PATH="$SCRIPT_DIRECTORY/.duplicity-passphrase"
BOTO_FILE_PATH="$SCRIPT_DIRECTORY/.boto"

# initialize constants
DEFAULT_RESTORE_DESTINATION_PATH="$SCRIPT_DIRECTORY/work"

# utils methods
sed_escape() {
  sed -e 's/[]\/$*.^[]/\\&/g'
}
writeConfig() {
  deleteConfig "$1"
  echo "$1=$2" >>"$SCRIPT_DIRECTORY/.theia"
}
readConfig() {
  test -f "$SCRIPT_DIRECTORY/.theia" && grep "^$(echo "$1" | sed_escape)=" "$SCRIPT_DIRECTORY/.theia" | sed "s/^$(echo "$1" | sed_escape)=//" | tail -1
}
deleteConfig() {
  test -f "$SCRIPT_DIRECTORY/.theia" && sed -i "/^$(echo $1 | sed_escape).*$/d" "$SCRIPT_DIRECTORY/.theia"
}

# initialize data file
touch .theia
mkdir -p $SCRIPT_DIRECTORY/work

# initialize setops
# saner programming env: these switches turn some bugs into errors
set -o errexit -o pipefail -o noclobber -o nounset

# -allow a command to fail with !’s side effect on errexit
# -use return value from ${PIPESTATUS[0]}, because ! hosed $?
! getopt --test >/dev/null
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
  echo "I’m sorry, $(getopt --test) failed in this environment."
  exit 1
fi

OPTIONS=vftm:i:e:o:d:r:f
LONG_OPTS=verbose,force,time,mode:,filter:,exclude:,full-backup-if-older-than:,remove-older-than:,remote-folder-to-restore:,force

# -regarding ! and PIPESTATUS see above
# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly
! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONG_OPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  # e.g. return value is 1
  #  then getopt has complained about wrong arguments to stdout
  exit 2
fi
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"
####################################
### END OF SEOPTS INITIALIZATION ###
####################################

FORCE="no"
VERBOSE="no"
TIME=""
MODE=""
FULL_BACKUP_IF_OLDER_THAN="7D"
REMOVE_OLDER_THAN="90D"
REMOTE_FOLDER_TO_RESTORE=""
FILTER=""
EXCLUDE=""

# handle options in order and nicely split until we see --
while true; do
  case "$1" in
  -v | --verbose)
    VERBOSE="yes"
    shift
    ;;
  -t | --time)
    TIME=$2
    shift 2
    ;;
  -m | --mode)
    MODE=$2
    case "$2" in
    "boto" | "backup" | "remove" | "restore" | "list-backups" | "list-files")
      shift 2
      ;;
    *)
      echo "Mode must be either 'boto' or 'backup' or 'remove' or 'restore' or 'list-backups' or 'list-files'"
      exit 3
      ;;
    esac
    ;;
  -i | --filter)
    if [[ $MODE != "list-files" ]]; then
      echo "Filtering is only allowed in 'list-files' mode"
      exit 3
    fi
    FILTER=$2
    shift 2
    ;;
  -e | --exclude)
    if [[ $MODE != "backup" ]]; then
      echo "Excluding is only allowed in 'backup' mode"
      exit 3
    fi
    EXCLUDE=$2
    shift 2
    ;;
  -o | --full-backup-if-older-than)
    if [[ $MODE != "backup" ]]; then
      echo "Full backup if older than option is only allowed in 'backup' mode"
      exit 3
    fi
    FULL_BACKUP_IF_OLDER_THAN=$2
    shift 2
    ;;
  -d | --remove-older-than)
    if [[ $MODE != "remove" ]]; then
      echo "Remove older than is only allowed in 'remove' mode"
      exit 3
    fi
    REMOVE_OLDER_THAN=$2
    shift 2
    ;;
  -r | --remote-folder-to-restore)
    if [[ $MODE != "restore" ]]; then
      echo "Remote folder to restore option is only allowed in 'restore' mode"
      exit 3
    fi
    REMOTE_FOLDER_TO_RESTORE=$2
    shift 2
    ;;
  -f | --force)
    if [[ $MODE != "restore" ]]; then
      echo "Force option is only allowed in 'restore' mode"
      exit 3
    fi
    FORCE="yes"
    shift
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Programming error"
    exit 3
    ;;
  esac
done

function showWelcomeMessage() {
  echo -e "\e[0m\033[2J\033[H"
  echo -e " __    __     _                                          _   _          _"
  echo -e "/ / /\ \ \___| | ___ ___  _ __ ___   ___    ___  _ __   | |_| |__   ___(_) __ _"
  echo -e "\ \/  \/ / _ \ |/ __/ _ \| '_ \` _ \ / _ \  / _ \| '_ \  | __| '_ \ / _ \ |/ _\` |"
  echo -e " \  /\  /  __/ | (_| (_) | | | | | |  __/ | (_) | | | | | |_| | | |  __/ | (_| |"
  echo -e "  \/  \/ \___|_|\___\___/|_| |_| |_|\___|  \___/|_| |_|  \__|_| |_|\___|_|\__,_|"
  echo -e ""
  echo -e "=================================================================================="
  echo -e ""
}

function checkWhetherBotoFileIsPresent() {
  if [[ ! -f $BOTO_FILE_PATH ]]; then
    echo "$BOTO_FILE_PATH file does not exist..."
    echo "Please initialize .boto file first"
    exit 4
  fi
}

if [[ ! -f $DUPLICITY_PASSPHRASE_FILE_PATH ]]; then
  echo "$DUPLICITY_PASSPHRASE_FILE_PATH file does not exist"
  exit 4
fi

# retrieve passphrase
for WORD in $(cat $DUPLICITY_PASSPHRASE_FILE_PATH); do
  PASSPHRASE=$WORD
done

function resetScreenToTop() {
  echo -e "\033[2J\033[H"
}

function showGenerateBotoMode() {
  resetScreenToTop

  echo -e " .oPYo. .oPYo. ooooo .oPYo.      d'b  o 8                                                      o               "
  echo -e " 8   \`8 8    8   8   8    8      8      8                                                      8               "
  echo -e "o8YooP' 8    8   8   8    8     o8P  o8 8 .oPYo.     .oPYo. .oPYo. odYo. .oPYo. oPYo. .oPYo.  o8P .oPYo. oPYo. "
  echo -e " 8   \`b 8    8   8   8    8      8    8 8 8oooo8     8    8 8oooo8 8' \`8 8oooo8 8  \`' .oooo8   8  8    8 8  \`' "
  echo -e " 8    8 8    8   8   8    8      8    8 8 8.         8    8 8.     8   8 8.     8     8    8   8  8    8 8     "
  echo -e " 8oooP' \`YooP'   8   \`YooP'      8    8 8 \`Yooo'     \`YooP8 \`Yooo' 8   8 \`Yooo' 8     \`YooP8   8  \`YooP' 8     "
  echo -e ":......::.....:::..:::.....::::::..:::....:.....::::::....8 :.....:..::..:.....:..:::::.....:::..::.....:..::::"
  echo -e ":::::::::::::::::::::::::::::::::::::::::::::::::::::::ooP'.:::::::::::::::::::::::::::::::::::::::::::::::::::"
  echo -e ":::::::::::::::::::::::::::::::::::::::::::::::::::::::...:::::::::::::::::::::::::::::::::::::::::::::::::::::"
  echo -e ""
  echo -e ""
  echo -e "For accessing credentials needed to generate a .boto file from Google Cloud Platform :"
  echo -e ""
  echo -e "\e[44mOPTION 1 - Easy way - Access directly with direct link\e[0m"
  echo -e "======================================================"
  echo -e ""
  echo -e "  \e[34m-\e[0m Click on this to access Google Cloud Storage credentials : \e[1m\e[42mhttps://console.cloud.google.com/storage/settings;tab=interoperability\e[0m"
  echo -e ""
  echo -e ""
  echo -e "\e[44mOPTION 2 - Manual way - Access manually if link does not work, or cannot be clicked\e[0m"
  echo -e "==================================================================================="
  echo -e ""
  echo -e "  \e[34m-\e[0m Navigate into Storage > Settings"
  echo -e "  \e[34m-\e[0m Go to interoperability tab"
  echo -e "  \e[34m-\e[0m Scroll down to the bottom of the page"
  echo -e "  \e[34m-\e[0m Locate \"Access keys for your user account\" section"
  echo -e ""
  echo -e ""

  echo -e "Deleting existing .boto file..."
  rm -fr $SCRIPT_DIRECTORY/.boto

  SCRIPT_UUID=$(uuidgen)
  echo -e "Preparing google cloud sdk .boto file generator script..."
  printf "" >"/tmp/generate-boto-$SCRIPT_UUID.bash"
  printf "#!/bin/bash\n" >>"/tmp/generate-boto-$SCRIPT_UUID.bash"
  printf "gcloud config set pass_credentials_to_gsutil false\n" >>"/tmp/generate-boto-$SCRIPT_UUID.bash"
  printf "gsutil config -a -o /credentials/.boto\n" >>"/tmp/generate-boto-$SCRIPT_UUID.bash"
  chmod u+x "/tmp/generate-boto-$SCRIPT_UUID.bash"

  echo -e "Launching google cloud sdk .boto file generator..."
  echo -e ""
  echo -e "--------------------"
  echo -e ""
  docker run --rm -it \
    -v "/tmp/generate-boto-$SCRIPT_UUID.bash":/generate-boto.bash \
    -v $SCRIPT_DIRECTORY:/credentials \
    google/cloud-sdk \
    "/generate-boto.bash"

  chmod 600 $SCRIPT_DIRECTORY/.boto

  rm -fr "$SCRIPT_DIRECTORY/tmp/generate-boto-$SCRIPT_UUID.bash"
}

function showRestoreMode() {
  resetScreenToTop
  checkWhetherBotoFileIsPresent

  echo -e " .oPYo.                 o                          8                    8"
  echo -e " 8   \`8                 8                          8                    8"
  echo -e "o8YooP' .oPYo. .oPYo.  o8P .oPYo. oPYo. .oPYo.     8oPYo. .oPYo. .oPYo. 8  .o  o    o .oPYo. "
  echo -e " 8   \`b 8oooo8 Yb..     8  8    8 8  \`' 8oooo8     8    8 .oooo8 8    ' 8oP'   8    8 8    8 "
  echo -e " 8    8 8.       'Yb.   8  8    8 8     8.         8    8 8    8 8    . 8 \`b.  8    8 8    8 "
  echo -e " 8    8 \`Yooo' \`YooP'   8  \`YooP' 8     \`Yooo'     \`YooP' \`YooP8 \`YooP' 8  \`o. \`YooP' 8YooP' "
  echo -e ":..:::..:.....::.....:::..::.....:..:::::.....::::::.....::.....::.....:..::...:.....:8 ....:"
  echo -e "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::8 :::::"
  echo -e "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::..:::::"
  echo -e ""
  echo -e ""
  echo -e "Duplicity is supporting \e[4ma very large amount\e[0m of URLs, and can be found here \e[42mhttp://duplicity.nongnu.org/vers8/duplicity.1.html#sect7\e[0m"
  echo -e ""
  echo -e "Here is a non-exhaustive list of supported URLs :"
  echo -e ""
  echo -e "  - \e[1mfile:///FOLDER_PATH\e[0m - Path for folder in current local filesystem"
  echo -e "    \e[43m\e[30m /!\ IMPORTANT NOTE /!\ \e[39m\e[49m \"file\" scheme must be followed by three \"/\", namely \"file://\" scheme followed by the first \"/\"\e[0m"
  echo -e "    of the absolute path."
  echo -e "    \e[0m\e[31mExemple of invalid path -> file://tmp/restore\e[21m\e[0m"
  echo -e "    \e[32mExemple of valid path -> file://\e[4m/\e[0m\e[32mtmp/restore\e[21m\e[0m"
  echo -e ""
  echo -e "  - \e[1mgs://GOOGLE_CLOUD_STORAGE_BUCKET_NAME[/FOLDER_PATH]\e[0m - Google Cloud Storage"
  echo -e ""
  echo -e "  - \e[1msftp://USERNAME[:PASSWORD]@HOSTNAME[:PORT]/[FOLDER_PATH]\e[0m - SFTP remote filesystem"
  echo -e ""

  if [[ -z ${RESTORE_DESTINATION_PATH+x} ]]; then
    writeConfig RESTORE_DESTINATION_PATH $DEFAULT_RESTORE_DESTINATION_PATH
  fi

  IS_RESTORE_DESTINATION_PATH_VALID=false
  while [[ $IS_RESTORE_DESTINATION_PATH_VALID == false ]]; do

    read -e -p "Choose an absolute folder to restore to [$(readConfig RESTORE_DESTINATION_PATH)]: " RESTORE_DESTINATION_PATH

    if [[ -z $RESTORE_DESTINATION_PATH ]]; then
      RESTORE_DESTINATION_PATH=$(readConfig RESTORE_DESTINATION_PATH)
    fi

    if [[ ! -d "$RESTORE_DESTINATION_PATH" ]]; then
      echo "\"$RESTORE_DESTINATION_PATH\" does not exist or is not a directory"
      continue
    fi

    tput cuu1
    tput el
    echo -e "Choose an absolute folder to restore to [$(readConfig RESTORE_DESTINATION_PATH)]"

    IS_RESTORE_DESTINATION_PATH_VALID=true
  done

  IS_RESTORE_SOURCE_LOCATION_VALID=false
  while [[ $IS_RESTORE_SOURCE_LOCATION_VALID == false ]]; do

    read -e -p "Choose an URL to restore from [$(readConfig RESTORE_SOURCE_URL)]: " RESTORE_SOURCE_URL

    if [[ -z "$RESTORE_SOURCE_URL" ]]; then
      if [[ -n $(readConfig RESTORE_SOURCE_URL) ]]; then
        RESTORE_SOURCE_URL=$(readConfig RESTORE_SOURCE_URL)
      else
        echo "URL to restore from is mandatory... Please enter a value"
        continue
      fi
    fi

    RESTORE_SOURCE_FILESYSTEM_PATH=""
    if [[ "$RESTORE_SOURCE_URL" =~ file://(.*?) ]]; then
      RESTORE_SOURCE_FILESYSTEM_PATH=$(echo $RESTORE_SOURCE_URL | sed 's/file:\/\///g')
      if [[ ! -d "$RESTORE_SOURCE_FILESYSTEM_PATH" ]]; then
        echo "\"$RESTORE_SOURCE_FILESYSTEM_PATH\" does not exist or is not a directory"
        continue
      fi
    fi

    while [[ -z "${COLLECT_STATUS+x}" || ! $COLLECT_STATUS =~ (y|n) ]]; do
      read -e -p "Do you want to list all backups contained in [$RESTORE_SOURCE_URL] (y/n) ? []: " COLLECT_STATUS
    done

    tput cuu1
    tput el
    echo -e "Do you want to list all backups contained in [$RESTORE_SOURCE_URL] ? [$COLLECT_STATUS]: "

    if [[ $COLLECT_STATUS =~ (y) ]]; then
      if [[ -n $RESTORE_SOURCE_FILESYSTEM_PATH ]]; then
        echo "Collecting eligible backups to restore from \"$RESTORE_SOURCE_FILESYSTEM_PATH\" folder..." | sed "s/.*/$(tput setaf 4)  \0$(tput init)/"
        docker 2>&1 run --rm --user $UID \
          -e PASSPHRASE=$PASSPHRASE \
          -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
          -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
          -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
          -v $RESTORE_SOURCE_FILESYSTEM_PATH:/work \
          sh4444dow/duplicity \
          duplicity --progress -v8 collection-status file:///work | sed "s/.*/$(tput setaf 027)   --| \0$(tput init)/g"
        writeConfig RESTORE_SOURCE_URL file://$RESTORE_SOURCE_FILESYSTEM_PATH
        IS_RESTORE_SOURCE_LOCATION_VALID=true
      else
        echo "Collecting eligible backups to restore from \"$RESTORE_SOURCE_URL\"..." | sed "s/.*/$(tput setaf 4)  \0$(tput init)/"
        docker 2>&1 run --rm --user $UID \
          -e PASSPHRASE=$PASSPHRASE \
          -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
          -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
          -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
          sh4444dow/duplicity \
          duplicity --progress -v8 collection-status $RESTORE_SOURCE_URL | sed "s/.*/$(tput setaf 4)   --| \0$(tput init)/"
        writeConfig RESTORE_SOURCE_URL $RESTORE_SOURCE_URL
        IS_RESTORE_SOURCE_LOCATION_VALID=true
      fi
    fi
    IS_RESTORE_SOURCE_LOCATION_VALID=true
  done

  IS_TIME_TO_RESTORE_VALID=false
  TIME_TO_RESTORE=""
  while [[ $IS_TIME_TO_RESTORE_VALID == false ]]; do
    read -p "Choose the time to restore [latest]: " TIME_TO_RESTORE
    IS_TIME_TO_RESTORE_VALID=true
  done

  FILE_TO_RESTORE_OPTION=""
  if [[ -n "$REMOTE_FOLDER_TO_RESTORE" ]]; then
    FILE_TO_RESTORE_OPTION="--file-to-restore $REMOTE_FOLDER_TO_RESTORE"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No remote folder to restore specified... Restoring all files..."
    fi
  fi

  TIME_OPTION=""
  if [[ -n "$TIME_TO_RESTORE" ]]; then
    TIME_OPTION="--time $TIME_TO_RESTORE"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No restore time specified... Taking last backup..."
    fi
  fi

  if [[ -n "$RESTORE_SOURCE_FILESYSTEM_PATH" ]]; then
    docker 2>&1 run --rm --user $UID \
      -e PASSPHRASE=$PASSPHRASE \
      -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
      -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
      -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
      -v $SCRIPT_DIRECTORY/work:/work \
      -v $RESTORE_SOURCE_FILESYSTEM_PATH:/data \
      sh4444dow/duplicity \
      duplicity --progress -v8 restore --force /data file:///work $FILE_TO_RESTORE_OPTION $TIME_OPTION | sed "s/.*/$(tput setaf 4)   --| \0$(tput init)/"
    echo ""
  else
    docker 2>&1 run --rm --user $UID \
      -e PASSPHRASE=$PASSPHRASE \
      -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
      -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
      -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
      -v $RESTORE_DESTINATION_PATH:/data \
      sh4444dow/duplicity \
      duplicity --progress -v8 restore --force $RESTORE_SOURCE_URL /data $FILE_TO_RESTORE_OPTION $TIME_OPTION | sed "s/.*/$(tput setaf 4)   --| \0$(tput init)/"
    echo ""
  fi
}

if [[ $MODE == "backup" ]]; then
  checkWhetherBotoFileIsPresent

  if [[ $# -ne 2 ]]; then
    echo "'backup' mode needs parameters [LOCAL_PATH_TO_BACKUP] [REMOTE_FOLDER_PATH]"
    exit 4
  fi

  if [[ $1 == "-" ]]; then
    if [[ $VERBOSE == "yes" ]]; then
      echo "Reading stdin..."
    fi
    LOCAL_PATH_TO_BACKUP=$(cat -)
  else
    LOCAL_PATH_TO_BACKUP=$1
  fi

  REMOTE_FOLDER_PATH=$2

  FULL_IF_OLDER_THAN_OPTION=""
  if [[ -n "$FULL_BACKUP_IF_OLDER_THAN" ]]; then
    FULL_IF_OLDER_THAN_OPTION="--full-if-older-than=$FULL_BACKUP_IF_OLDER_THAN"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No full backup time threshold specified..."
    fi
  fi

  EXCLUDE_OPTION=""
  if [[ -n "$EXCLUDE" ]]; then
    EXCLUDE_OPTION="--exclude=$EXCLUDE"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No excluding pattern specified... Taking all files..."
    fi
  fi

  docker run --rm --user $UID \
    -e PASSPHRASE=$PASSPHRASE \
    -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
    -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
    -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
    -v $LOCAL_PATH_TO_BACKUP:/data:ro \
    sh4444dow/duplicity \
    duplicity --progress --allow-source-mismatch $FULL_IF_OLDER_THAN_OPTION $EXCLUDE_OPTION /data $REMOTE_FOLDER_PATH
fi

if [[ $MODE == "remove" ]]; then
  checkWhetherBotoFileIsPresent

  if [[ $# -ne 1 ]]; then
    echo "'remove' mode needs parameters [REMOTE_FOLDER_PATH]"
    exit 4
  fi

  if [[ $1 == "-" ]]; then
    if [[ $VERBOSE == "yes" ]]; then
      echo "Reading stdin..."
    fi
    REMOTE_PATH_TO_REMOVE=$(cat -)
  else
    REMOTE_PATH_TO_REMOVE=$1
  fi

  if [[ -z "$REMOVE_OLDER_THAN" ]]; then
    echo "No remove threshold specified..."
    exit 4
  fi

  docker run --rm --user $UID \
    -e PASSPHRASE=$PASSPHRASE \
    -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
    -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
    -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
    sh4444dow/duplicity \
    duplicity remove-older-than --progress --force $REMOVE_OLDER_THAN $REMOTE_PATH_TO_REMOVE
fi

if [[ $MODE == "list-backups" ]]; then
  checkWhetherBotoFileIsPresent

  if [[ $# -ne 1 ]]; then
    echo "'list-backups' mode needs parameter [REMOTE_FOLDER_PATH]"
    exit 4
  fi

  REMOTE_FOLDER_PATH=$1

  TIME_OPTION=""
  if [[ -n "$TIME" ]]; then
    TIME_OPTION="--time=$TIME"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No restore time specified... Taking last backup..."
    fi
  fi

  docker run --rm --user $UID \
    -e PASSPHRASE=$PASSPHRASE \
    -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
    -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
    -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
    -v /opt/duplicity/work:/work \
    sh4444dow/duplicity \
    duplicity --progress collection-status $TIME_OPTION $REMOTE_FOLDER_PATH
fi

if [[ $MODE == "list-files" ]]; then
  checkWhetherBotoFileIsPresent

  if [[ $# -ne 1 ]]; then
    echo "'list-files' mode needs parameter [REMOTE_FOLDER_PATH]"
    exit 4
  fi

  REMOTE_FOLDER_PATH=$1

  TIME_OPTION=""
  if [[ -n "$TIME" ]]; then
    TIME_OPTION="--time=$TIME"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No restore time specified... Taking last backup..."
    fi
  fi

  FILTER_OPTION=""
  if [[ -n "$FILTER" ]]; then
    FILTER_OPTION=" | grep $FILTER"
  else
    if [[ $VERBOSE == "yes" ]]; then
      echo "No filter specified... Listing all files..."
    fi
  fi

  echo $REMOTE_FOLDER_PATH
  echo $TIME_OPTION
  echo $FILTER_OPTION

  docker run --rm --user $UID \
    -e PASSPHRASE=$PASSPHRASE \
    -v $SCRIPT_DIRECTORY/.cache:/home/duplicity/.cache/duplicity \
    -v $SCRIPT_DIRECTORY/.gnupg:/home/duplicity/.gnupg \
    -v $SCRIPT_DIRECTORY/.boto:/home/duplicity/.boto:ro \
    -v /opt/duplicity/work:/work \
    sh4444dow/duplicity \
    duplicity --progress list-current-files $TIME_OPTION $REMOTE_FOLDER_PATH $FILTER_OPTION
fi

# launch GUI if there is no argument
if [[ $# -eq 0 ]]; then
  showWelcomeMessage

  echo -e "    [1] Generate a .boto file"
  echo -e "    [2] Launch a backup on the fly"
  echo -e "    [3] Schedule a backup with cron"
  echo -e "    [4] Restore backup"
  echo -e ""

  read -p "Choose the mode number you want to use [1] : " MODE_NUMBER

  while true; do
    case "$MODE_NUMBER" in
    "")
      showGenerateBotoMode
      break 2
      ;;
    "1")
      showGenerateBotoMode
      break 2
      ;;
    "2")
      showBackupOnTheFlyMode
      break 2
      ;;
    "3")
      showBackupScheduleMode
      break 2
      ;;
    "4")
      showRestoreMode
      break 2
      ;;
    *)
      echo "$MODE_NUMBER : invalid selection"
      read -p "Choose the mode number you want to use [1] : " MODE_NUMBER
      ;;
    esac
  done
fi

exit 0
