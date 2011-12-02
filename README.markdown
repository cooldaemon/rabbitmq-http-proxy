## rabbitmq-http-proxy
RabbitMQ HTTP Proxy

### Building from Source
    % cd /path/to
    % hg clone http://hg.rabbitmq.com/rabbitmq-public-umbrella
    % cd rabbitmq-public-umbrella
    % make co
    % git clone git://github.com/cooldaemon/rabbitmq-http-proxy.git
    % cd ./rabbitmq-http-proxy
    % make

### Install
    % cd /path/to/rabbitmq-server
    % mkdir -p plugins
    % ln -s /path/to/rabbitmq-public-umbrella/rabbitmq-http-proxy/dist/rabbitmq_http_proxy-0.0.0.ez ./plugins/rabbitmq_http_proxy-0.0.0.ez
    % ./scripts/rabbitmq-plugins enable rabbitmq_http_proxy

### How to Use
    % /path/to/rabbitmq-server/scripts/rabbitmq-server -detached
    % perl /path/to/rabbitmq-public-umbrella/rabbitmq-http-proxy/sample_httpd_worker.pl
