"""
config.py — Principio SRP

Única responsabilidad: cargar y exponer la configuración del servicio.

## De dónde sale cada valor en Kubernetes

Nada de lo que hay aquí está escrito en el código de la aplicación ni en la
imagen. El chart de Helm arma dos objetos distintos y `envFrom` los inyecta:

  · **ConfigMap** — todo lo que se puede leer sin consecuencias: direcciones de
    servicios, tiempos de espera, nivel de log, nombre del exchange.
  · **Secret** — usuario y contraseña de PostgreSQL y de RabbitMQ. Nunca
    aparecen en un values versionado; `values.example.yaml` lleva ficticios.

La separación no es burocrática. Un ConfigMap se lee con un `kubectl get -o
yaml` que cualquiera con permiso de lectura puede ejecutar, y su contenido
aparece en los logs de depuración sin que nadie lo note. Meter una contraseña
ahí es filtrarla; por eso la credencial se construye aquí, en memoria, a partir
de dos variables que llegan por caminos distintos.

Nótese que aquí no aparece ninguna llave de JWT. `order-service` no valida
tokens: recibe la identidad ya resuelta en las cabeceras que inyecta el API
Gateway. Menos secretos en un servicio es menos superficie que proteger.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuración centralizada de order-service."""

    # --- Base de datos ---
    # Las piezas llegan separadas: host y nombre desde el ConfigMap, usuario y
    # contraseña desde el Secret. La cadena se arma en `database_url`.
    postgres_host: str = "sa-platform-postgresql"
    postgres_port: int = 5432
    postgres_db: str = "order_db"
    postgres_user: str = "order_user"
    postgres_password: str = ""

    # --- Aplicación ---
    app_env: str = "development"
    app_version: str = "2.0.0"
    log_level: str = "INFO"
    app_title: str = "order-service — Práctica 5"
    app_description: str = (
        "Microservicio de pedidos de la tienda en línea. Consulta precios al "
        "catálogo (GraphQL), registra el pedido y publica el evento en el "
        "broker. El aviso al cliente ya no forma parte de esta petición."
    )

    # --- Microservicios con los que habla ---
    # Se resuelven por el DNS interno de Kubernetes. Estas llamadas NO pasan
    # por el gateway: el gateway es la puerta de entrada desde afuera, y
    # obligar al tráfico interno a salir y volver solo agregaría latencia.
    catalog_service_url: str = "http://sa-platform-catalog-service:4000"

    # --- Broker de mensajería ---
    rabbitmq_host: str = "sa-platform-rabbitmq"
    rabbitmq_port: int = 5672
    rabbitmq_vhost: str = "/"
    rabbitmq_user: str = "sa_platform"
    rabbitmq_password: str = ""
    rabbitmq_exchange: str = "sa.events"

    # --- Tiempos de espera ---
    # El catálogo está en el camino crítico del checkout: sin precios no hay
    # pedido, y conviene fallar rápido.
    upstream_timeout_seconds: float = 5.0
    # Publicar en el broker es una escritura local a la red del clúster: si
    # tarda más de esto, algo está mal y no vale la pena hacer esperar al
    # cliente por un efecto secundario.
    publish_timeout_seconds: float = 3.0

    # --- CORS ---
    cors_origins: str = "http://sa-p5.local,http://localhost:8080"

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def database_url(self) -> str:
        """Cadena de conexión de SQLAlchemy, armada en memoria."""
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def amqp_url(self) -> str:
        """Cadena de conexión de AMQP, armada en memoria."""
        vhost = self.rabbitmq_vhost if self.rabbitmq_vhost != "/" else ""
        return (
            f"amqp://{self.rabbitmq_user}:{self.rabbitmq_password}"
            f"@{self.rabbitmq_host}:{self.rabbitmq_port}/{vhost}"
        )

    @property
    def cors_origins_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


settings = Settings()
