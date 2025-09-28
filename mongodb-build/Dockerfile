FROM mongo:6.0
USER root
RUN mkdir -p /data/db && chown -R mongodb:mongodb /data/db
USER mongodb
EXPOSE 27017
CMD ["mongod", "--bind_ip_all", "--noauth"]
