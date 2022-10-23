module Oxidized 

  class Zabbix < Source

    def initialize
      @cfg = Oxidized.config.source.zabbix
      super
    end

    def setup
      if @cfg.empty?
        Oxidized.asetus.user.source.zabbix.url       = "http://localhost/api_jsonrpc.php"
        Oxidized.asetus.user.source.zabbix.user      = "Admin"
        Oxidized.asetus.user.source.zabbix.password  = "zabbix"
        Oxidized.asetus.user.source.zabbix.token     = ""

        Oxidized.asetus.user.source.zabbix.map.model    = "{$OXIDIZED_MODEL}"
        Oxidized.asetus.user.source.zabbix.map.username = "{$OXIDIZED_USERNAME}"
        Oxidized.asetus.user.source.zabbix.map.password = "{$OXIDIZED_PASSWORD}"
        Oxidized.asetus.user.source.zabbix.map.template = "Template Oxidized"

        Oxidized.asetus.user.source.zabbix.vars_map.enable = "{$OXIDIZED_ENABLE}"

        Oxidized.asetus.save :user

        raise NoConfig, 'no source l config, edit ~/.config/oxidized/config'
      end
    end

    require "net/http"
    require "json"

    def load(node_want = nil)

      if (@cfg.token.nil?) then
        token = zabbix_user_login(@cfg.user.to_s, @cfg.password.to_s)
      else
        token = @cfg.token.to_s
      end
      result = zabbix_template_get(@cfg.template, token)

      if result.length == 0
        exit
      end

      hostids = []
      result[0]["hosts"].each do | host |
        hostids.push(host["hostid"])
      end

      hosts = zabbix_host_get(hostids, token)
      ifaces = zabbix_hostinterface_get(hosts.keys, token)
      macros = zabbix_usermacro_get(hosts.keys, token)

      nodes = []
      hosts.keys.each do | hostid |
        node = {}
        node.update(hosts[hostid])  if hosts.has_key?(hostid)
        node.update(ifaces[hostid]) if ifaces.has_key?(hostid)
        node.update(macros[hostid]) if macros.has_key?(hostid)

        node[:model] = map_model node[:model] if node.has_key? :model
        node[:group] = map_group node[:group] if node.has_key? :group

        nodes.push(node)
      end
      nodes

    end

    private

    def zabbix_api(method, params, token = nil)
      uri = URI.parse(@cfg.url.to_s)

      http = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      response = http.post(
        uri.request_uri,
        {
          jsonrpc: "2.0",
          id: "0",
          method: method,
          params: params,
          auth: token
        }.to_json,
        { "Content-Type" => "application/json-rpc" }
      )

      JSON.parse(response.body)["result"]
    end

    def zabbix_user_login(user, password)
      zabbix_api(
        "user.login",
        {
          user: user,
          password: password
        }
      )
    end

    def zabbix_template_get(name, token)
      zabbix_api(
        "template.get",
        {
          output: "hosts",
          selectHosts: [],
          filter: {
            host: name
          }
        },
        token
      )
    end

    def zabbix_host_get(hostids, token)
      result = zabbix_api(
        "host.get",
        {
          output: ["hostid", "host", "name"],
          hostids: hostids,
          filter: {
            status: "0"
          }
        },
        token
      )

      items = {}
      result.each do | item |
        hostid = item["hostid"]
        items[hostid] = {} if not items.has_key?(hostid)

        items[hostid][:name] = node_var_interpolate(item["host"])
      end
      items
    end

    def zabbix_hostinterface_get(hostids, token)
      result = zabbix_api(
        "hostinterface.get",
        {
          output: ["hostid", "useip", "ip", "dns"],
          hostids: hostids,
          filter: {
            available: "1"
          }
        },
        token
      )

      items = {}
      result.each do | item |
        hostid = item["hostid"]
        items[hostid] = {} if not items.has_key?(hostid)

        items[hostid][:ip] = item["useip"] == "1" ? node_var_interpolate(item["ip"]) : node_var_interpolate(item["dns"])
      end
      items
    end

    def zabbix_usermacro_get(hostids, token)

      macronames = []
      @cfg.map.each do | k, v |
        macronames.push(v.to_s)
      end
      @cfg.vars_map.each do | k, v |
        macronames.push(v.to_s)
      end

      result = zabbix_api(
        "usermacro.get",
        {
          output: ["hostid", "macro", "value"],
          hostids: hostids,
          filter: {
            macro: macronames
          }
        },
        token
      )

      items = {}
      result.each do | item |
        hostid = item["hostid"]
        items[hostid] = {} unless items.has_key?(hostid)

        @cfg.map.each do | k, v |
          items[hostid][k.to_sym] = node_var_interpolate(item["value"]) if item["macro"] == v.to_s
        end

        items[hostid][:vars] = {} unless items[hostid].has_key?(:vars)
        @cfg.vars_map.each do | k, v |
          items[hostid][:vars][k.to_sym] = node_var_interpolate(item["value"]) if item["macro"] == v.to_s
        end

      end
      items
    end

  end

end
