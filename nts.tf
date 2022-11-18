job "chrony_nts_server" {
    datacenters = ["dc1"]
    type = "service"

    group "docker" {
        count = 2

        network {
            port "ntp" {
                to = "123"
            }
            port "nts" {
                to = "4460"
            }
        }

        update {
            max_parallel = 1
            min_healthy_time = "10s"
            healthy_deadline = "60s"
            progress_deadline = "2m"
            auto_revert = true
            auto_promote = true
            canary = 1
        }

        service {
            name = "chrony-ntp"
            port = "ntp"
        }

        service {
            name = "chrony-nts"
            port = "nts"

            check {
                name = "NTS Service"
                port = "nts"
                type = "tcp"
                interval = "30s"
                timeout = "1s"
            }
        }

        volume "letsencrypt" {
            type      = "host"
            read_only = false
            source    = "letsencrypt"
        }

        task "chrony-container" {
            driver = "docker"
            volume_mount {
                volume      = "letsencrypt"
                destination = "/opt/letsencrypt"
                read_only   = false
           }

            env {
                NTP_SERVERS = "0.de.pool.ntp.org,time.cloudflare.com,time1.google.com"
                LOG_LEVEL = "1"
            }

            config {
                image = "my.gitlab.com:12345/server_management/chrony-nts:latest"
                ports = ["ntp", "nts"]
                network_mode = "default"
                force_pull = true

                auth {
                    username = "myuser"
                    password = "mypassword"
                }
            }
        }
    }
}