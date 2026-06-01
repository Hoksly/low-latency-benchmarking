#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <liburing.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#define RING_DEPTH 64
#define BUF_SIZE 4096
int main(int argc, char *argv[]) {
    const char *ip = argc > 1 ? argv[1] : "0.0.0.0";
    int port = argc > 2 ? atoi(argv[2]) : 11113;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in a = {.sin_family=AF_INET, .sin_port=htons(port)};
    inet_pton(AF_INET, ip, &a.sin_addr);
    if (bind(fd,(struct sockaddr*)&a,sizeof(a))<0){perror("bind");return 1;}
    struct io_uring ring;
    io_uring_queue_init(RING_DEPTH, &ring, 0);
    printf("io_uring UDP echo on %s:%d\n", ip, port); fflush(stdout);
    char rbuf[BUF_SIZE], sbuf[BUF_SIZE];
    struct sockaddr_in peer; socklen_t peerlen;
    struct iovec riov={.iov_base=rbuf,.iov_len=BUF_SIZE};
    struct iovec siov={.iov_base=sbuf};
    struct msghdr rmsg={.msg_name=&peer,.msg_namelen=sizeof(peer),.msg_iov=&riov,.msg_iovlen=1};
    struct msghdr smsg={.msg_iov=&siov,.msg_iovlen=1};
    struct io_uring_cqe *cqe; struct io_uring_sqe *sqe;
    for(;;) {
        peerlen=sizeof(peer); rmsg.msg_namelen=peerlen; riov.iov_len=BUF_SIZE;
        sqe=io_uring_get_sqe(&ring); io_uring_prep_recvmsg(sqe,fd,&rmsg,0);
        sqe->user_data=1; io_uring_submit_and_wait(&ring,1);
        io_uring_wait_cqe(&ring,&cqe);
        int n=cqe->res; io_uring_cqe_seen(&ring,cqe);
        if(n<=0) continue;
        memcpy(sbuf,rbuf,n); siov.iov_len=n;
        smsg.msg_name=&peer; smsg.msg_namelen=sizeof(peer);
        sqe=io_uring_get_sqe(&ring); io_uring_prep_sendmsg(sqe,fd,&smsg,MSG_DONTWAIT);
        sqe->user_data=2; io_uring_submit_and_wait(&ring,1);
        io_uring_wait_cqe(&ring,&cqe); io_uring_cqe_seen(&ring,cqe);
    }
}
