FROM debian:13

# Установка необходимых пакетов
RUN apt-get update && \
    apt-get install -y \
    ansible \
    openssh-client \
    sshpass \
    git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Создание рабочей директории
WORKDIR /ansible

# Копирование ansible файлов
COPY ansible/ /ansible/

# Создание директории для SSH ключей
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

CMD ["/bin/bash"]
