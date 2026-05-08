profile cmd='' name='':
    #!/bin/bash
    if [ -z "{{cmd}}" ]; then
        docker-compose exec hermes bash -c "if ! command -v hermes &>/dev/null; then source /opt/hermes/.venv/bin/activate; fi; cd /opt/data; bash"
    else
        docker-compose exec hermes bash -c "/opt/hermes/.venv/bin/hermes profile {{cmd}} {{name}}"
    fi

logs nline='50':
    docker-compose logs hermes --tail {{nline}}

restart:
    docker-compose restart hermes
