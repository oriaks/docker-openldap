FROM oriaks/debian:latest
MAINTAINER Michael Richard <michael.richard@oriaks.com>

VOLUME ["/var/lib/ldap"]
EXPOSE 389/tcp 636/tcp

COPY entrypoint.sh /entrypoint.sh
RUN ["/entrypoint.sh","install"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["init"]
