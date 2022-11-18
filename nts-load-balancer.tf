job "chrony_ingress" {
  datacenters = ["dc1"]

  group "nginx" {
    count = 1

    network {
      mode = "host"
      port "http" {
          static = "80"
      }
      port "https" {
          static = "443"
      }
      port "ntp" {
          static = "123"
      }
      port "nts" {
          static = "4460"
      }
    }

    service {
        name = "chrony-ingress-http"
        port = "http"

        check {
            name     = "HTTP Health"
            port     = "http"
            path     = "/"
            type     = "http"
            protocol = "http"
            interval = "10s"
            timeout  = "2s"
        }
    }

    service {
        name = "chrony-ingress-https"
        port = "https"
    }

    service {
        name = "chrony-ingress-ntp"
        port = "ntp"
    }

    service {
        name = "chrony-ingress-nts"
        port = "nts"
    }

    volume "letsencrypt" {
        type      = "host"
        read_only = true
        source    = "letsencrypt"
    }

    task "ingress-container" {
      driver = "docker"

      volume_mount {
            volume      = "letsencrypt"
            destination = "/opt/letsencrypt" #in the container
            read_only   = false
      }

      config {
        network_mode = "host"
        image = "nginx:alpine"
        ports = ["http","https", "ntp", "nts"]
        volumes = [
          "local/nginx/nginx.conf:/etc/nginx/nginx.conf",
          "local/nginx/dhparam.pem:/etc/nginx/ssl/dhparam.pem",
          "local/nginx/ssl-params.conf:/etc/nginx/ssl/ssl-params.conf",
          "local/nginx/default.conf:/etc/nginx/conf.d/default.conf",
          "local/nginx/stream.conf:/etc/nginx/conf.d/stream.conf",
          "local/nginx/buffers.conf:/etc/nginx/conf.d/buffers.conf",
          "local/nginx/timeouts.conf:/etc/nginx/conf.d/timeouts.conf",
          "local/nginx/header.conf:/etc/nginx/conf.d/header.conf",
          "local/nginx/cache.conf:/etc/nginx/conf.d/cache.conf",
          "local/nginx/gzip.conf:/etc/nginx/conf.d/gzip.conf",
          #  Generate/serve HTML that can be used to monitor the certificate (e.g. Zabbix)
          "local/nginx/index.html:/usr/share/nginx/html/index.html"
        ]
      }


      # nginx.conf
      template {
        data = <<EOH
user  nginx;
worker_processes  auto;
worker_rlimit_nofile  15000;
pid  /var/run/nginx.pid;
include /usr/share/nginx/modules/*.conf;


events {
    worker_connections  2048;
    multi_accept on;
    use epoll;
}

stream {
    include /etc/nginx/conf.d/stream.conf;
}


http {
    default_type   application/octet-stream;
    # access_log   /var/log/nginx/access.log;
    # activate the server access log only when needed
    access_log     off;
    error_log      /var/log/nginx/error.log;
    # don't display server version on error pages
    server_tokens  off;
    server_names_hash_bucket_size 64;
    include        /etc/nginx/mime.types;
    sendfile       on;
    tcp_nopush     on;
    tcp_nodelay    on;

    charset utf-8;
    source_charset utf-8;
    charset_types text/xml text/plain text/vnd.wap.wml application/javascript application/rss+xml;
    
    include /etc/nginx/conf.d/default.conf;
    include /etc/nginx/conf.d/buffers.conf;
    include /etc/nginx/conf.d/timeouts.conf;
    include /etc/nginx/conf.d/cache.conf;
    include /etc/nginx/conf.d/gzip.conf;
}
        EOH

        destination = "local/nginx/nginx.conf"
      }


      # default.conf
      template {
        data = <<EOH
server {
    listen 80;
    listen [::]:80;

    server_name my.nts-server.com;

    return 301 https://$server_name$request_uri;
}


server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl;
    ssl_certificate /opt/letsencrypt/live/my.nts-server.com/fullchain.pem;
    ssl_certificate_key /opt/letsencrypt/live/my.nts-server.com/privkey.pem;
    include ssl/ssl-params.conf;
    include /etc/nginx/conf.d/header.conf;

    server_name  my.nts-server.com;

    #access_log  /var/log/nginx/host.access.log  main;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
    }

    #error_page  404              /404.html;

    # redirect server error pages to the static page /50x.html
    #
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }
}
        EOH

        destination = "local/nginx/default.conf"
      }


      # stream.conf
      template {
        data = <<EOH
upstream chrony-ntp {
  {{ range service "chrony-ntp" }}
    server {{ .Address }}:{{ .Port }};
  {{ else }}server 127.0.0.1:65535; # force a 502
  {{ end }}
}

upstream chrony-nts {
  {{ range service "chrony-nts" }}
    server {{ .Address }}:{{ .Port }};
  {{ else }}server 127.0.0.1:65535; # force a 502
  {{ end }}
}

server {
        listen 123 udp;
        listen 123; #tcp
        proxy_pass chrony-ntp;
        error_log  /var/log/nginx/ntp.log info;
        proxy_responses 1;
        proxy_timeout   1s;
}

server {
      listen 4460 udp;
      listen 4460; #tcp
      proxy_pass chrony-nts;
      error_log  /var/log/nginx/nts.log info;
      proxy_responses 1;
      proxy_timeout   1s;
}
        EOH

        destination = "local/nginx/stream.conf"
      }


      # index.html
      template {
        data = <<EOH
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to my.nts-server.com!</title>
</head>
<body>
    <h1>Welcome to my.nts-server.com!</h1>
</body>
</html>
        EOH

        destination = "local/nginx/index.html"
      }


      # dhparam.pem
      template {
        data = <<EOH
-----BEGIN DH PARAMETERS-----
MIICCAKCA...

....

...CAQI=
-----END DH PARAMETERS-----
        EOH

        destination = "local/nginx/dhparam.pem"
      }


      # ssl-params.conf
      template {
        data = <<EOH
ssl_protocols TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_dhparam /etc/nginx/ssl/dhparam.pem;
ssl_ciphers ECDH+AESGCM:ECDH+CHACHA20:ECDH+AES256:ECDH+AES128:!aNULL:!SHA1:!AESCCM;
ssl_conf_command Options PrioritizeChaCha;
ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256;
ssl_ecdh_curve secp384r1; # Requires nginx >= 1.1.0
ssl_session_timeout  10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off; # Requires nginx >= 1.5.9
ssl_stapling on; # Requires nginx >= 1.3.7
ssl_stapling_verify on; # Requires nginx => 1.3.7
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Frame-Options "";
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
        EOH

        destination = "local/nginx/ssl-params.conf"
      }


      # buffers.conf
      template {
        data = <<EOH
client_body_buffer_size 10k;
client_header_buffer_size 1k;
client_max_body_size 8m;
large_client_header_buffers 2 1k;
# Directive needs to be increased for certain site types to prevent ERROR 400
# large_client_header_buffers 4 32k;
        EOH

        destination = "local/nginx/buffers.conf"
      }


      # header.conf
      template {
        data = <<EOH
add_header                Cache-Control  "public, must-revalidate, proxy-revalidate, max-age=0";
proxy_set_header          X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header          X-NginX-Proxy true;
proxy_set_header          X-Real-IP $remote_addr;
proxy_set_header          X-Forwarded-Proto http;
proxy_hide_header         X-Frame-Options;
proxy_set_header          Accept-Encoding "";
proxy_http_version        1.1;
proxy_set_header          Upgrade $http_upgrade;
proxy_set_header          Connection "upgrade";
proxy_set_header          Host $host;
proxy_cache_bypass        $http_upgrade;
proxy_max_temp_file_size  0;
proxy_redirect            off;
proxy_read_timeout        240s;
        EOH

        destination = "local/nginx/header.conf"
      }


      # cache.conf
      template {
        data = <<EOH
open_file_cache max=1500 inactive=20s;
open_file_cache_valid 30s;
open_file_cache_min_uses 5;
open_file_cache_errors off;
        EOH

        destination = "local/nginx/cache.conf"
      }


      # timeouts.conf
      template {
        data = <<EOH
client_header_timeout 3m;
client_body_timeout 3m;
keepalive_timeout 100;
keepalive_requests 1000;
send_timeout 3m;
        EOH

        destination = "local/nginx/timeouts.conf"
      }


      # gzip.conf
      template {
        data = <<EOH
gzip on;
gzip_disable "msie6";
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 256;
gzip_buffers 16 8k;
gzip_http_version 1.1;
gzip_types text/plain text/css application/json application/javascript
text/xml application/xml application/xml+rss text/javascript
image/svg+xml application/xhtml+xml application/atom+xml;
        EOH

        destination = "local/nginx/gzip.conf"
      }

    }
  }
}