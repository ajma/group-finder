#!/usr/bin/env ruby

require "base64"
require "cgi"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "uri"
require "yaml"

namespace :groups do
  namespace :get do
    desc "Create a json file with all the group's information"
    task :listings do

      if !File.exists?("groups.yaml")
        puts "Missing configuration file (groups.yaml)"
        puts
        puts "Example:"
        puts "    :user_token: '<user token>'"
        puts "    :secret_key: '<secret key>'"
        puts "    :api_sleep: 0.5"
        puts "    :data_dir: 'data'"
        puts "    :campuses:"
        puts "        Bellevue: 'BEL.json'"
        puts "        Sammamish: 'SAM.json'"
        exit
      end

      $config = YAML.load_file("groups.yaml")

      if $config[:user_token].empty?
        puts "Did you forget to enter a user_token in the config?"
        exit
      elsif $config[:secret_key].empty?
        puts "Did you forget to enter a secret_key in the config?"
        exit
      end

      $output = Hash.new
      $tmp_dir = ".tmp"
      if File.directory?($tmp_dir)
        FileUtils.rm_rf($tmp_dir)
      end
      FileUtils.mkdir_p($tmp_dir)
      $errorOutput = File.new("#{$tmp_dir}/errors.txt", "w");

      def fetch_json(url)
        unix_time = Time.now.to_i
        http_verb = "GET"
        string_to_sign = "#{unix_time}#{http_verb}#{url}"

        unencoded_hmac = OpenSSL::HMAC.digest("sha256", $config[:secret_key], string_to_sign)
        unescaped_hmac = Base64.encode64(unencoded_hmac).chomp
        hmac_signature = CGI.escape(unescaped_hmac)

        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        data = Object.new
        http.start do |http|
          request = Net::HTTP::Get.new(uri.request_uri)
          request["X-City-Sig"] = hmac_signature
          request["X-City-User-Token"] = $config[:user_token]
          request["X-City-Time"] = unix_time
          request["Accept"] = "application/vnd.thecity.admin.v1+json"
          response = http.request(request)        
          data = response.body
        end
        return JSON.parse(data)
      end

      def check_data(group)
        errors = Array.new
        if group["description"].nil? || group["description"].empty?
          errors << " - missing description"
        end

        if group["address"]["lat"].nil?
          errors << " - missing address"
        end

        days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        if (days & group["tags"]).empty?
          errors << " - missing meeting day"
        end

        if !errors.empty?
          $errorOutput.write("#{group["name"]} (ID: #{group["id"]}) has incomplete information:\n#{errors.join("\n")}\n\n");
        end
      end

      def fetch_groups(page = 1)
        groups_url = "https://api.onthecity.org/groups?group_types=CG&page=#{page}"
            # puts groups_url
            json = fetch_json(groups_url)
            groups_json = json["groups"]
            total_pages = json["total_pages"]    
            puts "Fetching groups page #{page} of #{total_pages}"

            if groups_json
              groups_json.each do |group_json|
                campus = group_json["campus_name"]
                if !campus.nil?
                  campus = campus.strip
                  if $config[:campuses].keys.include?(campus)
                    group = fetch_group(group_json)

                    check_data(group)

                    if !group["address"]["lat"].nil?
                      if $output[campus].nil?
                        $output[campus] = File.new("#{$tmp_dir}/#{$config[:campuses][campus]}", "w")
                        $output[campus].write("[")
                      else
                        $output[campus].write(",")
                      end
                      $output[campus].write(group.to_json + "\n")
                      $output[campus].flush
                    else
                      puts "Skipping #{group["name"]} due to missing address"
                    end
                    sleep $config[:api_sleep]
                  else
                    puts "Skipping group from #{campus}"
                  end
                end
              end
            else
              puts "Invalid group json returned"
            end
            $errorOutput.flush 

            if page < total_pages
              fetch_groups(page + 1)
            end
          end

          def fetch_group(group_json)
            id = group_json["id"]
            name = group_json["name"]
            name = name.strip if name
            puts "  Processing group #{id}: #{name}"
            url = group_json["internal_url"]
            campus = group_json["campus_name"]
            description = group_json["external_description"]
            description = description.strip if description
            tags = fetch_tags(id)

            {
              "id" => id,
              "name" => name, 
              "church" => campus,
              "description" => description, 
              "address" => fetch_address(id),
              "leaders" => fetch_leaders(id),
              "tags" => tags
            }    
          end

          def fetch_address(id)
            address_url = "https://api.onthecity.org/groups/#{id}/addresses"
            json = fetch_json(address_url)
            address = json["addresses"][0]

            if address
              lat = address["latitude"]
              long = address["longitude"]
              name = address["friendly_name"]
              street = address["street"]
              street2 = address["street2"]
              city = address["city"]
              state = address["state"]
              zipcode = address["zipcode"]
            end

            return {
              "lat" => lat, 
              "long" => long, 
              "name" => name,
              "street" => street, 
              "street2" => street2, 
              "city" => city, 
              "state" => state, 
              "zipcode" => zipcode
            }
          end

          def fetch_leaders(id)
            leaders = Array.new
            leaders_url = "https://api.onthecity.org/groups/#{id}/roles?title=Leaders"
            leaders_json = fetch_json(leaders_url)["roles"]
            leaders_json.each do |leader_json|
              user_id = leader_json["user_id"]
              user_url = "https://api.onthecity.org/users/#{user_id}"
              user_json = fetch_json(user_url)
              leaders << { "name" => leader_json["user_name"],
                "email" => user_json["email"],
                "phone" => user_json["primary_phone"] }
              end

              return leaders
            end

            def fetch_tags(id)
              tags = Array.new
              tags_url = "https://api.onthecity.org/groups/#{id}/tags"
              tags_json = fetch_json(tags_url)["tags"]
              tags_json.each do |tag_json|
                tags << tag_json["name"]
              end

              return tags
            end


            fetch_groups()

            manifest = File.new("#{$tmp_dir}/manifest.json", "w")
            manifest.write("{ \"generated_on\": \"#{Time.now.utc}\",")
            manifest.write("\"churches\": [")
            $output.keys.each_with_index do |campus, index|
              if(index > 0)
                manifest.write(",")
              end
              manifest.write("\"#{$config[:campuses][campus]}\"")
            # write closing tag for all output files
            $output[campus].write("]")
          end
          manifest.write("]}")

          # move tmp to data dir
          FileUtils.rm_rf($config[:data_dir])
          FileUtils.mv("#{$tmp_dir}", $config[:data_dir])
        end
      end
    end
