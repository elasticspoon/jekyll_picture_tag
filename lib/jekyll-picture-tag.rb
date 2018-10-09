# Title: Jekyll Picture Tag
# Authors: Rob Wierzbowski : @robwierzbowski
#          Justin Reese    : @justinxreese
#          Welch Canavan   : @xiwcx
#
# Description: Easy responsive images for Jekyll.
#
# Download: https://github.com/robwierzbowski/jekyll-picture-tag
# Documentation: https://github.com/robwierzbowski/jekyll-picture-tag/readme.md
# Issues: https://github.com/robwierzbowski/jekyll-picture-tag/issues
#
# Syntax:  {% picture [preset] path/to/img.jpg [source_key: path/to/alt-img.jpg] [attr="value"] %}
# Example: {% picture poster.jpg alt="The strange case of responsive images" %}
#          {% picture gallery poster.jpg source_small: poster_closeup.jpg
#             alt="The strange case of responsive images" class="gal-img" data-selected %}
#
# See the documentation for full configuration and usage instructions.

require 'fileutils'
require 'pathname'
require 'digest/md5'
require 'mini_magick'
require 'fastimage'
require 'objective_elements'

module Jekyll
  class Picture < Liquid::Tag
    attr_reader :context
    def initialize(tag_name, raw_params, tokens)
      @raw_params = raw_params
      super
    end

    def render_markup
      # Render any liquid variables in tag arguments and unescape template code
      Liquid::Template.parse(@raw_params)
                      .render(context)
                      .gsub(/\\\{\\\{|\\\{\\%/, '\{\{' => '{{', '\{\%' => '{%')
    end

    def site
      # Global site data
      context.registers[:site]
    end

    def settings
      # picture config from _config.yml
      site.config['picture']
    end

    def url
      # site url
      site.config['url'] || ''
    end

    def baseurl
      site.config['baseurl'] || ''
    end

    def markup
      # Regex is hard. Markup is the argument passed to the tag.
      # Raw argument example example:
      # [preset] img.jpg [source_key: alt-img.jpg] [attr=\"value\"]
      /^(?:(?<preset>[^\s.:\/]+)\s+)?(?<image_src>[^\s]+\.[a-zA-Z0-9]{3,4})\s*(?<source_src>(?:(source_[^\s.:\/]+:\s+[^\s]+\.[a-zA-Z0-9]{3,4})\s*)+)?(?<html_attr>[\s\S]+)?$/.match(render_markup)
    end

    def preset
      # Which batch of image sizes to put together
      settings['presets'][ markup[:preset] ] || settings['presets']['default']
    end

    def instance
      # instance is a deep copy of the preset.
      Marshal.load(Marshal.dump(preset))
    end

    def source_src
      if markup[:source_src]
        Hash[*markup[:source_src].delete(':').split]
      else
        {}
      end
    end

    def assign_defaults
      settings['source'] ||= '.'
      settings['output'] ||= 'generated'
      settings['markup'] ||= 'picturefill'
    end

    def render(context)
      @context = context
      # Gather settings

      unless markup
        raise <<-HEREDOC
        Picture Tag can't read this tag. Try {% picture [preset] path/to/img.jpg [source_key:
        path/to/alt-img.jpg] [attr=\"value\"] %}.
        HEREDOC
      end

      assign_defaults

      # Prevent Jekyll from erasing our generated files
      unless site.config['keep_files'].include?(settings['output'])
        site.config['keep_files'] << settings['output']
      end

      # Process html attributes
      html_attr = if markup[:html_attr]
                    Hash[*markup[:html_attr].scan(/(?<attr>[^\s="]+)(?:="(?<value>[^"]+)")?\s?/).flatten]
                  else
                    {}
                  end

      html_attr = instance.delete('attr').merge(html_attr) if instance['attr']

      if settings['markup'] == 'picturefill'
        html_attr['data-picture'] = nil
        html_attr['data-alt'] = html_attr.delete('alt')
      end

      html_attr_string = html_attr.inject('') do |string, attrs|
        string << if attrs[1]
                    "#{attrs[0]}=\"#{attrs[1]}\" "
                  else
                    "#{attrs[0]} "
                  end
      end

      # Prepare ppi variables
      ppi = instance['ppi'] ? instance.delete('ppi').sort.reverse : nil
      ppi_sources = {}

      # Switch width and height keys to the symbols that generate_image()
      # expects
      instance.each do |key, source|
        if !source['width'] && !source['height']
          raise "Preset #{key} is missing a width or a height"
        end

        instance[key][:width] = instance[key].delete('width') if source['width']
        instance[key][:height] = instance[key].delete('height') if source['height']
      end

      # Store keys in an array for ordering the instance sources
      source_keys = instance.keys
      # used to escape markdown parsing rendering below
      markdown_escape = "\ "

      # Raise some exceptions before we start expensive processing
      unless preset
        raise <<-HEREDOC
          Picture Tag can't find the "#{markup[:preset]}" preset. Check picture: presets in _config.yml for a list of presets.
        HEREDOC
      end

      unless (source_src.keys - source_keys).empty?
        raise <<-HEREDOC
          Picture Tag can't find this preset source. Check picture: presets: #{markup[:preset]} in _config.yml for a list of sources.
        HEREDOC
      end

      # Process instance
      # Add image paths for each source
      instance.each_key do |key|
        instance[key][:src] = source_src[key] || markup[:image_src]
      end

      # Construct ppi sources Generates -webkit-device-ratio and resolution: dpi
      # media value for cross browser support Reference:
      # http://www.brettjankord.com/2012/11/28/cross-browser-retinahigh-resolution-media-queries/
      if ppi
        instance.each do |key, source|
          ppi.each do |p|
            next unless p != 1

            ppi_key = "#{key}-x#{p}"

            ppi_sources[ppi_key] = {
              :width => source[:width] ? (source[:width].to_f * p).round : nil,
              :height => source[:height] ? (source[:height].to_f * p).round : nil,
              'media' => if source['media']
                           "#{source['media']} and (-webkit-min-device-pixel-ratio: #{p}), #{source['media']} and (min-resolution: #{(p * 96).round}dpi)"
                         else
                           "(-webkit-min-device-pixel-ratio: #{p}), (min-resolution: #{(p * 96).to_i}dpi)"
                           end,
              :src => source[:src]
            }

            # Add ppi_key to the source keys order
            source_keys.insert(source_keys.index(key), ppi_key)
          end
        end
        instance.merge!(ppi_sources)
      end

      # Generate resized images
      instance.each do |key, source|
        instance[key][:generated_src] = generate_image(source, site.source, site.dest, settings['source'], settings['output'], baseurl)
      end

      # Construct and return tag
      if settings['markup'] == 'picture'
        source_tags = ''
        source_keys.each do |source|
          media = " media=\"#{instance[source]['media']}\"" unless source == 'source_default'
          source_tags += "#{markdown_escape * 4}<source srcset=\"#{url}#{instance[source][:generated_src]}\"#{media}>\n"
        end

        # Note: we can't indent html output because markdown parsers will turn 4 spaces into code blocks
        # Note: Added backslash+space escapes to bypass markdown parsing of indented code below -WD
        picture_tag = "<picture>\n"\
                      "#{source_tags}"\
                      "#{markdown_escape * 4}<img src=\"#{url}#{instance['source_default'][:generated_src]}\" #{html_attr_string}>\n"\
                      "#{markdown_escape * 2}</picture>\n"
      elsif settings['markup'] == 'interchange'

        interchange_data = []
        source_keys.reverse_each do |source|
          interchange_data << "[#{url}#{instance[source][:generated_src]}, #{source == 'source_default' ? '(default)' : instance[source]['media']}]"
        end

        picture_tag = %(<img data-interchange="#{interchange_data.join ', '}" #{html_attr_string} />\n)
        picture_tag += %(<noscript><img src="#{url}#{instance['source_default'][:generated_src]}" #{html_attr_string} /></noscript>)

      elsif settings['markup'] == 'img'
        # TODO: Implement sizes attribute
        picture_tag = SingleTag.new 'img'

        source_keys.each do |source|
          val = "#{url}#{instance[source][:generated_src]} #{instance[source][:width]}w,"
          picture_tag.add_attributes srcset: val
          # Note the last value will have a comma hanging off the end of it.
        end
        picture_tag.add_attributes src: "#{url}#{instance['source_default'][:generated_src]}"
        picture_tag.add_attributes html_attr_string
      end

      # Return the markup!
      picture_tag.to_s
    end

    def generate_image(instance, site_source, site_dest, image_source, image_dest, baseurl)
      begin
        digest = Digest::MD5.hexdigest(File.read(File.join(site_source, image_source, instance[:src]))).slice!(0..5)
      rescue Errno::ENOENT
        warn 'Warning:'.yellow + " source image #{instance[:src]} is missing."
        return ''
      end

      image_dir = File.dirname(instance[:src])
      ext = File.extname(instance[:src])
      basename = File.basename(instance[:src], ext)

      size = FastImage.size(File.join(site_source, image_source, instance[:src]))
      orig_width = size[0]
      orig_height = size[1]
      orig_ratio = orig_width * 1.0 / orig_height

      gen_width = if instance[:width]
                    instance[:width].to_f
                  elsif instance[:height]
                    orig_ratio * instance[:height].to_f
                  else
                    orig_width
                  end
      gen_height = if instance[:height]
                     instance[:height].to_f
                   elsif instance[:width]
                     instance[:width].to_f / orig_ratio
                   else
                     orig_height
                   end
      gen_ratio = gen_width / gen_height

      # Don't allow upscaling. If the image is smaller than the requested dimensions, recalculate.
      if orig_width < gen_width || orig_height < gen_height
        undersize = true
        gen_width = orig_ratio < gen_ratio ? orig_width : orig_height * gen_ratio
        gen_height = orig_ratio > gen_ratio ? orig_height : orig_width / gen_ratio
      end

      gen_name = "#{basename}-#{gen_width.round}by#{gen_height.round}-#{digest}#{ext}"
      gen_dest_dir = File.join(site_dest, image_dest, image_dir)
      gen_dest_file = File.join(gen_dest_dir, gen_name)

      # Generate resized files
      unless File.exist?(gen_dest_file)

        warn 'Warning:'.yellow + " #{instance[:src]} is smaller than the requested output file. It will be resized without upscaling." if undersize

        #  If the destination directory doesn't exist, create it
        FileUtils.mkdir_p(gen_dest_dir) unless File.exist?(gen_dest_dir)

        # Let people know their images are being generated
        puts "Generating #{gen_name}"

        image = MiniMagick::Image.open(File.join(site_source, image_source, instance[:src]))
        # Scale and crop
        image.combine_options do |i|
          i.resize "#{gen_width}x#{gen_height}^"
          i.gravity 'center'
          i.crop "#{gen_width}x#{gen_height}+0+0"
          i.strip
        end

        image.write gen_dest_file
      end

      # Return path relative to the site root for html
      Pathname.new(File.join(baseurl, image_dest, image_dir, gen_name)).cleanpath
    end
  end
end

Liquid::Template.register_tag('picture', Jekyll::Picture)
