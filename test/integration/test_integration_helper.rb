require 'test_helper'
module TestIntegrationHelper
  include TestHelper
  include PictureTag

  # PictureTag inherits from a basic Liquid tag, which helps it to interact with
  # jeckyll but isn't necessary to test our code.

  ContextStub = Struct.new(:environments, :registers)
  SiteStub = Struct.new(:config, :data, :source, :dest)
  TokenStub = Struct.new(:line_number, :locale)

  def tested(params = 'rms.jpg')
    PictureTag::Picture
      .send(:new, 'picture', params, TokenStub.new(true, 'something'))
      .render(@context)
  end

  def rms_filename(width: 100, format: 'jpg')
    "/tmp/jpt/generated/rms-#{width}-46a48b.#{format}"
  end

  def spx_filename(width: 100, format: 'jpg')
    "/tmp/jpt/generated/spx-#{width}-2e8bb3.#{format}"
  end

  def rms_file_array(widths, formats)
    files = formats.collect do |f|
      widths.collect { |w| rms_filename(width: w, format: f) }
    end

    files.flatten
  end

  def spx_file_array(widths, formats)
    files = formats.collect do |f|
      widths.collect { |w| spx_filename(width: w, format: f) }
    end

    files.flatten
  end

  def base_stubs
    build_defaults
    build_site_stub
    build_context_stub
    stub_liquid
  end

  def stub_console
    PictureTag::GeneratedImage.any_instance.stubs(:puts)
    PictureTag::Utils.stubs(:warning)
  end

  def build_context_stub
    environments = [{ 'jekyll' => { 'environment' => @jekyll_env } }]
    registers = {
      site: @site,
      page: @page
    }

    @context = ContextStub.new(environments, registers)
  end

  def build_defaults
    @pconfig = {}
    @pdata = {}
    @jekyll_env = 'development'
    @jconfig = { 'picture' => @pconfig, 'keep_files' => [] }
    @data = { 'picture' => @pdata }
    @page = { 'ext' => 'html' }
    @site_source = TEST_DIR
    @site_dest = '/tmp/jpt'
  end

  def build_site_stub
    @site = SiteStub.new(
      @jconfig, @data, @site_source, @site_dest
    )
  end

  def stub_liquid
    Liquid::Template.stubs(:register_tag)

    # Liquid::Template.parse(params).render(context)
    template_stub = Object.new
    Liquid::Template.stubs(:parse).with do |params|
      template_stub.define_singleton_method(:render) { |_context| params }
    end.returns(template_stub)
  end

  def cleanup_files
    FileUtils.rm_rf('/tmp/jpt/')
  end
end
