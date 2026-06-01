#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <ff_api.h>
#include <ff_epoll.h>

#define PORT 11114
#define BUF_SIZE 4096

static int epfd;
static int sock_fd;
static char buf[BUF_SIZE];

int loop(void *arg) {
    struct epoll_event events[64];
    int nev = ff_epoll_wait(epfd, events, 64, 0);
    for (int i = 0; i < nev; i++) {
        int fd = events[i].data.fd;
        if (events[i].events & EPOLLIN) {
            struct linux_sockaddr_storage from;
            socklen_t fl = sizeof(from);
            int n = ff_recvfrom(fd, buf, BUF_SIZE, 0,
                                (struct linux_sockaddr *)&from, &fl);
            if (n > 0) {
                ff_sendto(fd, buf, n, 0,
                          (struct linux_sockaddr *)&from, fl);
            }
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    ff_init(argc, argv);
    sock_fd = ff_socket(AF_INET, SOCK_DGRAM, 0);
    struct linux_sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    ff_bind(sock_fd, (struct linux_sockaddr *)&addr, sizeof(addr));
    epfd = ff_epoll_create(1);
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = sock_fd};
    ff_epoll_ctl(epfd, EPOLL_CTL_ADD, sock_fd, &ev);
    printf("F-Stack UDP echo on port %d\n", PORT);
    ff_run(loop, NULL);
    return 0;
}
