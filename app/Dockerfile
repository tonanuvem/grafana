# Serve a pagina do LAB 2. O build valida o conteudo: se os campos ou o botao
# de planilha sumirem, ele falha AQUI, e nao numa tela em branco na aula.
FROM alpine:3.20 AS build
COPY index.html /w/index.html
RUN set -e; \
    grep -q 'id="integrantes"' /w/index.html; \
    grep -q 'gerar()'          /w/index.html; \
    grep -q 'deploy.sh'        /w/index.html; \
    grep -q 'decisao.sh'       /w/index.html

FROM nginx:1.27-alpine
COPY --from=build /w/index.html /usr/share/nginx/html/index.html
HEALTHCHECK --interval=5s --timeout=3s --retries=6 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
