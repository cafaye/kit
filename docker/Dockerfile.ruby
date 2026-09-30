# kit template — Ruby service image. Copy to docker/Dockerfile in the service repo.
#
#   docker build -f docker/Dockerfile --build-arg RUBY_VERSION=3.4.4 -t svc .
#
# STRICTNESS NOTES
#   - Two stages. The final stage is `ruby:*-slim`, not `ruby:*`: full Debian
#     ships a browser, a docs toolchain, and ~400 MB that a service never calls.
#   - The final stage runs non-root, as `app` (uid 10001), created with a fixed
#     numeric uid so the image is reproducible. A container running as root is a
#     container where a bug is a host compromise.
#   - `BUNDLE_PATH=/usr/local/bundle` keeps gems out of the app user's home so a
#     non-root runtime user can read them without chmod-ing the whole tree.
#   - `BUNDLE_WITHOUT=development:test` is the single most useful line in this
#     file: it keeps test-only gems (capybara, rspec-rails, rubocop) out of
#     production, so a test dependency can never be a production CVE.
#   - Bundle in the builder, run in the runtime stage. A `bundle install` at
#     runtime writes to the image filesystem on every boot; that is how a
#     read-only-rootfs deployment starts failing.
ARG RUBY_VERSION=3.4

FROM ruby:${RUBY_VERSION}-slim AS build
ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=true
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

FROM ruby:${RUBY_VERSION}-slim AS runtime
ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=true \
    RAILS_ENV=production
WORKDIR /app
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --create-home app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=app:app . /app
USER app
EXPOSE 3000
ENTRYPOINT ["bin/rails", "server", "-b", "0.0.0.0"]
