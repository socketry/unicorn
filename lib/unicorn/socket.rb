require 'fcntl'
require 'socket'
require 'io/nonblock'

# non-portable Socket code goes here:
class Socket
  module Constants
    # configure platform-specific options (only tested on Linux 2.6 so far)
    case RUBY_PLATFORM
    when /linux/
      # from /usr/include/linux/tcp.h
      TCP_DEFER_ACCEPT = 9 unless defined?(TCP_DEFER_ACCEPT)
      TCP_CORK = 3 unless defined?(TCP_CORK)
    when /freebsd(([1-4]\..{1,2})|5\.[0-4])/
    when /freebsd/
      # Use the HTTP accept filter if available.
      # The struct made by pack() is defined in /usr/include/sys/socket.h
      # as accept_filter_arg
      unless `/sbin/sysctl -nq net.inet.accf.http`.empty?
        unless defined?(SO_ACCEPTFILTER_HTTPREADY)
          SO_ACCEPTFILTER_HTTPREADY = ['httpready',nil].pack('a16a240').freeze
        end

      end
    end
  end
end

class UNIXSocket
  UNICORN_PEERADDR = '127.0.0.1'.freeze
  def unicorn_peeraddr
    UNICORN_PEERADDR
  end
end

class TCPSocket
  def unicorn_peeraddr
    peeraddr.last
  end
end

module Unicorn
  module SocketHelper
    include Socket::Constants

    def set_client_sockopt(sock)
      sock.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1) if defined?(TCP_NODELAY)
      sock.setsockopt(SOL_TCP, TCP_CORK, 1) if defined?(TCP_CORK)
    end

    def set_server_sockopt(sock)
      if defined?(TCP_DEFER_ACCEPT)
        sock.setsockopt(SOL_TCP, TCP_DEFER_ACCEPT, 1) rescue nil
      end
      if defined?(SO_ACCEPTFILTER_HTTPREADY)
        sock.setsockopt(SOL_SOCKET, SO_ACCEPTFILTER,
                        SO_ACCEPTFILTER_HTTPREADY) rescue nil
      end
    end

    # creates a new server, socket. address may be a HOST:PORT or
    # an absolute path to a UNIX socket.  address can even be a Socket
    # object in which case it is immediately returned
    def bind_listen(address = '0.0.0.0:8080', backlog = 1024)
      return address if address.kind_of?(Socket)

      domain, bind_addr = if address[0..0] == "/"
        [ AF_UNIX, Socket.pack_sockaddr_un(address) ]
      elsif address =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/
        [ AF_INET, Socket.pack_sockaddr_in($2.to_i, $1) ]
      else
        raise ArgumentError, "Don't know how to bind: #{address}"
      end

      sock = Socket.new(domain, SOCK_STREAM, 0)
      sock.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1) if defined?(SO_REUSEADDR)
      begin
        sock.bind(bind_addr)
      rescue Errno::EADDRINUSE
        sock.close rescue nil
        return nil
      end
      sock.listen(backlog)
      set_server_sockopt(sock) if domain == AF_INET
      sock
    end

    # Returns the configuration name of a socket as a string.  sock may
    # be a string value, in which case it is returned as-is
    # Warning: TCP sockets may not always return the name given to it.
    def sock_name(sock)
      case sock
      when String then sock
      when UNIXServer
        Socket.unpack_sockaddr_un(sock.getsockname)
      when TCPServer
        Socket.unpack_sockaddr_in(sock.getsockname).reverse!.join(':')
      when Socket
        begin
          Socket.unpack_sockaddr_in(sock.getsockname).reverse!.join(':')
        rescue ArgumentError
          Socket.unpack_sockaddr_un(sock.getsockname)
        end
      else
        raise ArgumentError, "Unhandled class #{sock.class}: #{sock.inspect}"
      end
    end

    # casts a given Socket to be a TCPServer or UNIXServer
    def server_cast(sock)
      begin
        Socket.unpack_sockaddr_in(sock.getsockname)
        TCPServer.for_fd(sock.fileno)
      rescue ArgumentError
        UNIXServer.for_fd(sock.fileno)
      end
    end

  end # module SocketHelper
end # module Unicorn