#!/bin/sh

_usage () {
  cat <<- EOF
	Usage: $0 build                        Build images
	       $0 start                        Start services
	       $0 stop                         Stop services
	       $0 restart                      Restart services
	       $0 manage SERVICE [ARG...]      Manage a running service
	       $0 shell SERVICE                Open a shell in the running service

EOF
}

_DIR=`cd "$( dirname "$0" )" && pwd`
_PROJECT=`basename "${_DIR}"`
_CMD="$1"
_SERVICE="$2"

[ -n "${_CMD}" ] && shift
[ -n "${_SERVICE}" ] && shift

case "${_CMD}" in
  "build")
    docker-compose build
    ;;
  "manage")
    [ -z "${_PROJECT}" -o -z "${_SERVICE}" ] && _usage || docker exec -it "${_PROJECT}_${_SERVICE}" /entrypoint.sh manage $*
    ;;
  "restart")
    docker-compose restart
    ;;
  "start")
    docker-compose up -d
    ;;
  "shell")
    [ -z "${_PROJECT}" -o -z "${_SERVICE}" ] && _usage || docker exec -it "${_PROJECT}_${_SERVICE}" /entrypoint.sh shell
    ;;
  "stop")
    docker-compose stop
    ;;
  *)
    _usage
    ;;
esac
