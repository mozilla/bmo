=========================
BMO: bugzilla.mozilla.org
=========================

BMO is Mozilla's highly customized version of Bugzilla.

.. image:: https://readthedocs.org/projects/bmo/badge/?version=latest
    :target: https://bmo.readthedocs.io/en/latest/?badge=latest
    :alt: Documentation Status

.. image:: https://github.com/mozilla-bteam/bmo/actions/workflows/deploy.yml/badge.svg
    :target: https://github.com/mozilla-bteam/bmo/actions

.. contents::
..
    1.  Using Docker Compose (For Development)
    2.  Docker Container
      2.1  Container Arguments
      2.2  Environmental Variables
      2.3  Logging Configuration
    3. Development Tips
      3.1  Testing Emails
    4. Administrative Tasks
      4.1  Generating cpanfile and cpanfile.snapshot files
      4.2  Generating a new bmo-perl-slim base image
    5. Support

If you want to contribute to BMO, you can fork this repo and get a local copy
of BMO running in a few minutes using Docker.


Using Docker (For Development)
==============================

This repository contains a docker-compose file that will create a local Bugzilla for testing.

To use Docker Compose, ensure you have the latest `Docker <https://docs.docker.com/get-started/get-docker/>`_
install for your environment (Linux, Windows, or macOS).

.. code-block:: bash

    docker compose up --build

This command will bring up the main webserver process, database, memcached, and various other
background tasks such as the Push system and the Feed system. The latter two are used for workflow
management between bugzilla.mozilla.org and other external systems.

For normal development, you can run just the main webserver, database, and memcached by running the
following command instead:

.. code-block:: bash

    docker compose up --build bmo.test

After that, you should be able to visit http://localhost:8000/ from your browser.
You can login as admin@mozilla.bugs with the password "password012!" (without
quotes).

If you want to update the code running in the web container, you do not need to restart everything.
You can run the following command:

.. code-block:: bash

    docker compose exec bmo.test rsync -avz --exclude .git --exclude local /mnt/sync/ /app/

The Mojolicious morbo development server, used by the web container, will notice any code changes and
restart itself.

The third-party front-end libraries (jQuery, Prism, mermaid, and so on) are not committed to the
repository. They are generated at image build time, so they exist in the container but not in your
checkout, and the ``rsync`` above leaves them alone. See `Front-end Libraries`_ for how to add or
upgrade one.

If you are using Visual Studio Code, these ``docker compose`` commands will come in handy as the
editor's `tasks`_ that can be found under the Terminal menu. The update command is assigned to the
default build task so it can be executed by simply hitting Ctrl+Shift+B on Windows/Linux or
Command+Shift+B on macOS. An `extension bundle`_ for VS Code is also available.

.. _`tasks`: https://code.visualstudio.com/docs/editor/tasks
.. _`extension bundle`: https://marketplace.visualstudio.com/items?itemName=dylanwh.bugzilla


Docker Container
================

This repository is also a runnable docker container.

Container Arguments
-------------------

Currently, the entry point takes a single command argument.
This can be **httpd** or **shell**.

httpd
    This will start the web server listening for connections on ``$PORT``
shell
    This will start an interactive shell in the container. Useful for debugging.


Environmental Variables
-----------------------

PORT
  This must be a value >= 1024. The httpd will listen on this port for incoming
  plain-text HTTP connections.
  Default: 8000

MOJO_REVERSE_PROXY
  This tells the backend that it is behind a proxy.
  Default: 1

MOJO_HEARTBEAT_INTERVAL
  How often (in seconds) will the manager process send a heartbeat to the workers.
  Default: 10

MOJO_HEARTBEAT_TIMEOUT
  Maximum amount of time in seconds before a worker without a heartbeat will be stopped gracefully
  Default: 120

MOJO_INACTIVITY_TIMEOUT
  Maximum amount of time in seconds a connection can be inactive before getting closed.
  Default: 120

MOJO_WORKERS
  Number of worker processes. A good rule of thumb is two worker processes per
  CPU core for applications that perform mostly non-blocking operations,
  blocking operations often require more and benefit from decreasing
  concurrency with "MOJO_CLIENTS" (often as low as 1). Note that during zero
  downtime software upgrades there will be twice as many workers active for a
  short amount of time.
  Default: 1

MOJO_SPARE
  Temporarily spawn up to this number of additional workers if there is a
  need. This allows for new workers to be started while old ones are still
  shutting down gracefully, drastically reducing the performance cost of
  worker restarts.
  Default: 1

MOJO_CLIENTS
  Maximum number of accepted connections each worker process is allowed to
  handle concurrently, before stopping to accept new incoming connections. Note
  that high concurrency works best with applications that perform mostly
  non-blocking operations, to optimize for blocking operations you can decrease
  this value and increase "MOJO_WORKERS" instead for better performance.
  Default: 200

BUGZILLA_ALLOW_INSECURE_HTTP
  This should never be set in production. It allows oauth over http.

BMO_urlbase
  The public URL for this instance. Note that if this begins with https://
  and BMO_inbound_proxies is set to '*' Bugzilla will believe the connection to it
  is using SSL.

BMO_canonical_urlbase
  The public URL for the production instance, if different from urlbase above.

BMO_attachment_base
  This is the URL for attachments.
  When the allow_attachment_display parameter is on, it is possible for a
  malicious attachment to steal your cookies or perform an attack on Bugzilla
  using your credentials.

  If you would like additional security on attachments to avoid this, set this
  parameter to an alternate URL for your Bugzilla that is not the same as
  urlbase. That is, a different domain name that resolves to this
  exact same Bugzilla installation.

  For added security, you can insert %bugid% into the URL, which will be
  replaced with the ID of the current bug that the attachment is on, when you
  access an attachment. This will limit attachments to accessing only other
  attachments on the same bug. Remember, though, that all those possible domain
  names (such as 1234.your.domain.com) must point to this same Bugzilla
  instance.

BMO_db_driver
  What SQL database to use. Default is mysql. List of supported databases can be
  obtained by listing Bugzilla/DB directory - every module corresponds to one
  supported database and the name of the module (before ".pm") corresponds to a
  valid value for this variable.

BMO_db_host
  The DNS name or IP address of the host that the database server runs on.

BMO_db_name
  The name of the database.

BMO_db_user
  The database user to connect as.

BMO_db_pass
  The password for the user above.

BMO_site_wide_secret
  This secret key is used by your installation for the creation and
  validation of encrypted tokens. These tokens are used to implement
  security features in Bugzilla, to protect against certain types of attacks.
  It's very important that this key is kept secret.

BMO_jwt_secret
  This secret key is used by your installation for the creation and validation
  of jwts.  It's very important that this key is kept secret and it should be
  different from the site_wide_secret. Changing this will invalidate all issued
  jwts, so all oauth clients will need to start over. As such it should be a
  high level of entropy, as it probably won't change for a very long time.

BMO_inbound_proxies
  This is a list of IP addresses that we expect proxies to come from.
  This can be '*' if only the load balancer can connect to this container.
  Setting this to '*' means that BMO will trust the X-Forwarded-For header.

BMO_memcached_namespace
  The global namespace for the memcached servers.

BMO_memcached_servers
  A list of memcached servers (IP addresses or host names). Can be empty.

BMO_shadowdb
  The database name of the read-only database.

BMO_shadowdbhost
  The hostname or IP address of the read-only database.

BMO_shadowdbport
   The port of the read-only database.

BMO_setrlimit
    This is a JSON object and can set any limit described in https://metacpan.org/pod/BSD::Resource.
    Typically it used for setting RLIMIT_AS, and the default value is ``{ "RLIMIT_AS": 2000000000 }``.

BMO_size_limit
  This is the max amount of unshared memory the worker processes are allowed to
  use before they will exit. Minimum 750000 (750MiB)

BMO_mail_delivery_method
  Usually configured on the MTA section of admin interface, but may be set here for testing purposes.
  Valid values are None, Test, Sendmail, or SMTP.
  If set to Test, email will be appended to the /app/data/mailer.testfile.

BMO_use_mailer_queue
  Usually configured on the MTA section of the admin interface, you may change this here for testing purposes.
  Should be 1 or 0. If 1, the job queue will be used. For testing, only set to 0 if the BMO_mail_delivery_method is None or Test.

USE_NYTPROF
  Write `Devel::NYTProf`_ profiles out for each request.
  These will be named /app/data/nytprof.$host.$script.$n.$pid, where $host is
  the hostname of the container, script is the name of the script (without
  extension), $n is a number starting from 1 and incrementing for each
  request to the worker process, and $pid is the worker process id.

NYTPROF_DIR
  Alternative location to store profiles from the above option.

LOG4PERL_CONFIG_FILE
  Filename of `Log::Log4perl`_ config file.
  It defaults to log4perl-json.conf.
  If the file is given as a relative path, it will be relative to the /app/conf/ directory.

.. _`Devel::NYTProf`: https://metacpan.org/pod/Devel::NYTProf

.. _`Log::Log4perl`: https://metacpan.org/pod/Log::Log4perl

LOG4PERL_STDERR_DISABLE
  Boolean. By default log messages are logged as plain text to `STDERR`.
  Setting this to a true value disables this behavior.

  Note: For programs that run using the `cereal` log aggregator, this environment
  variable will be ignored.


Logging Configuration
---------------------

How Bugzilla logs is entirely configured by the environmental variable
`LOG4PERL_CONFIG_FILE`.  This config file should be familiar to someone
familiar with log4j, and it is extensively documented in `Log::Log4perl`_.

Many examples are provided in the ``conf/`` directory.

If multiple processes will need to log, it should be configured to log to a socket on port 5880.
This will be the "cereal" daemon, which will only be started for jobqueue and httpd-type containers.

The example log config files will often be configured to log to stderr
themselves.  To prevent duplicate lines (or corrupted log messages), stderr
logging should be filtered on the existence of the LOG4PERL_STDERR_DISABLE
environmental variable.

Logging configuration also controls which errors are sent to Sentry.


Development Tips
================

Test Suite
----------

Bugzilla comes with several integrated test suites that do basic sanity checks to more involved web UI testing. To
execute the tests, run the following commands:

Basic sanity tests

.. code-block:: bash

  docker compose -f docker-compose.test.yml down && docker compose -f docker-compose.test.yml run --no-deps bmo.test test_sanity

Webservices API tests

.. code-block:: bash

  docker compose -f docker-compose.test.yml down && docker compose -f docker-compose.test.yml run bmo.test test_webservices

Selenium Web UI tests

.. code-block:: bash

  docker compose -f docker-compose.test.yml down && docker compose -f docker-compose.test.yml run bmo.test test_selenium

Testing Emails
--------------

Configure your MTA setting you want to use by going to http://localhost:8000/editparams.cgi?section=mta
and changing the mail_delivery_method to 'Test'. With this option, all mail will be appended to a
``data/mailer.testfile``. To see the emails being sent:

.. code-block:: bash

  docker compose run bmo.test cat /app/data/mailer.testfile

Front-end Libraries
-------------------

The third-party front-end libraries BMO serves — their scripts, stylesheets, images and icon fonts —
are generated from the versions pinned in ``package.json`` and ``package-lock.json``. None of the
generated files are committed: the ``assets`` stage in the ``Dockerfile`` runs
``scripts/build-frontend.mjs`` and the result is copied over ``/app/js`` in the image. Node exists
only in that stage, so the runtime image stays Node-free.

This means a Dependabot pull request that bumps a library is complete on its own — there is nothing
to regenerate and commit, and CI tests the upgraded library as-is. Because a library's stylesheet is
generated from the same package as its script, the two cannot drift apart, so review upgrades for
visual changes as well as behavioural ones. Treat major bumps (jquery 4.x, mermaid 13.x,
devbridge-autocomplete 2.x) as manual, tested reviews.

To add a new library:

1. Add it to ``dependencies`` in ``package.json``, pinned to an exact version, then run
   ``npm install`` to update ``package-lock.json``.

2. Add an entry to ``TARGETS`` in ``scripts/build-frontend.mjs`` mapping the path BMO serves it from
   (relative to ``js/``) to the file inside ``node_modules``. The mapping is explicit because the
   names BMO serves do not always match the names upstream ships, and because only the files BMO
   actually needs belong in the image:

   .. code-block:: javascript

     'lib/newlib.min.js': 'newlib/dist/newlib.min.js',
     'lib/newlib.css': 'newlib/dist/newlib.min.css',

   A library whose stylesheet references images or fonts by relative URL needs those too. Copy the
   whole directory by adding it to ``TARGET_DIRS`` instead, so the assets land next to the
   stylesheet that references them — this is how contextMenu's icon font and jQuery UI's images are
   handled:

   .. code-block:: javascript

     'jquery/plugins/contextMenu/font': 'jquery-contextmenu/dist/font',

3. If the library lands in a directory that also holds committed files, add the generated paths to
   ``.gitignore``. Adding to an existing generated directory such as ``js/lib/`` needs no change,
   since the whole directory is already ignored.

4. Load it from the template that needs it, the same as any other asset:

   .. code-block:: text

     [% javascript_urls.push('js/lib/newlib.min.js') %]
     [% style_urls.push('js/lib/newlib.css') %]

jQuery plugins are a special case. ``template/en/default/global/header.html.tmpl`` builds their
paths by convention from the name pushed onto the ``jquery`` array::

  js/jquery/plugins/<name>/<name>-min.js

So a plugin's ``TARGETS`` entry has to follow that layout, and templates load it with
``[% jquery.push('name') %]`` rather than a literal path. ``js/jquery/plugins/bPopup/`` is the one
library still vendored in the repository, because it is not published to npm.

To rebuild after changing any of this, rebuild the image. If you want the generated files in your
working tree — to serve BMO from a checkout directly, for instance — run:

.. code-block:: bash

  npm ci && npm run build

Technical Details
-----------------

This Docker environment is a very scaled-down version of production BMO.
It uses roughly the same Perl dependencies as production. It is also
configured to use memcached. The push connector and Phabricator feed daemon
are running but connect to local test services rather than production systems.

It includes a couple example products, some fake users, and some of BMO's
real groups. Email is disabled for all users; however, it is safe to enable
email as the box is configured to send all email to the 'admin' user on the
container.


Administrative Tasks
====================

Generating cpanfile and cpanfile.snapshot files
-----------------------------------------------

.. code-block:: bash

  docker build -t bmo-cpanfile -f Dockerfile.cpanfile .
  docker run -it -v "$(pwd):/app/result" bmo-cpanfile cp cpanfile cpanfile.snapshot /app/result

Generating a new bmo-perl-slim base image
------------------------------------------------------

The ``bmo-perl-slim`` base image is stored in Google Artifact Registry. It
contains just the Perl dependencies in ``/app/local`` and other Debian packages
needed. Whenever the ``cpanfile`` and ``cpanfile.snapshot`` files have been
changed by the above steps after a successful merge, a new image will need to
be built and pushed.

This is handled by the ``BMO Perl Slim`` GitHub Actions workflow
(``.github/workflows/perl-slim.yml``), which can be triggered manually via
``workflow_dispatch``. It builds the image and pushes it to Google Artifact
Registry with a date-stamped tag.

After the new image is pushed, update the ``FROM`` line in ``Dockerfile`` to
reference the new tag. Create a PR, review and commit the change.


Support
==============================

You can chat with the BMO team on `Matrix <https://chat.mozilla.org/#/room/#bmo:mozilla.org>`_.
