FROM nginx:1.27-alpine

# Static configs
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/security.conf /etc/nginx/conf.d/security.conf
COPY conf.d/metrics.conf /etc/nginx/conf.d/metrics.conf

# Template configs (envsubst at runtime)
COPY conf.d/upstream-api.conf /etc/nginx/templates/upstream-api.conf.template
COPY conf.d/upstream-chat.conf /etc/nginx/templates/upstream-chat.conf.template
COPY conf.d/upstream-ai.conf /etc/nginx/templates/upstream-ai.conf.template
COPY conf.d/upstream-frontend.conf /etc/nginx/templates/upstream-frontend.conf.template
COPY sites-available/default /etc/nginx/templates/default.conf.template

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 80 443 8888

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
