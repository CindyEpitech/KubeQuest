# ─────────────────────────────────────────────────────────────────────────────
#  Multi-stage build — keep build-only tooling (composer, git, unzip) and dev
#  dependencies OUT of the final image. Only the runtime + app + prod vendor ship.
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: install PHP dependencies (no dev deps, optimised autoloader) ─────
# The official composer image already bundles git + unzip, so none of that has
# to land in the runtime image.
FROM composer:2 AS vendor
WORKDIR /app

# Copy only the dependency manifests first so this layer is cached unless the
# dependencies actually change.
COPY composer.json composer.lock ./
RUN composer install \
      --no-dev \
      --prefer-dist \
      --no-scripts \
      --no-autoloader \
      --no-interaction

# Now bring in the source and build the optimised production autoloader.
# --no-scripts: don't run `artisan package:discover` at build time (it would
# boot the app without an .env); Laravel rebuilds that cache on first run.
COPY . .
RUN composer dump-autoload --optimize --no-dev --no-scripts

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM php:8.2-apache AS runtime

# pdo_mysql is the only extension the app needs; docker-php-ext-install builds it
# against libraries already present in the base image — no apt packages required.
RUN docker-php-ext-install pdo_mysql && a2enmod rewrite

# Serve Laravel's public/ directory.
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
 && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

WORKDIR /var/www/html

# App source (host vendor/.git excluded via .dockerignore) + the prod vendor
# directory built in stage 1.
COPY --chown=www-data:www-data . /var/www/html
COPY --chown=www-data:www-data --from=vendor /app/vendor /var/www/html/vendor

# Only these two trees need to be writable by the web server at runtime.
RUN chmod -R 775 storage bootstrap/cache

EXPOSE 80
