#
# This source file is part of appleseed.
# Visit https://appleseedhq.net/ for additional information and resources.
#
# This software is released under the MIT license.
#
# Copyright (c) 2014-2018 The appleseedhq Organization
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

import array
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
from math import ceil

import appleseed as asr
import bpy

from .renderercontroller import FinalRendererController, InteractiveRendererController
from .tilecallbacks import FinalTileCallback
from .. import util
from ..logger import get_logger
from ..translators.preview import PreviewRenderer
from ..translators.scene import SceneTranslator

logger = get_logger()

_preview_renderer = None


class RenderThread(threading.Thread):
    def __init__(self, renderer):
        super(RenderThread, self).__init__()
        self.__renderer = renderer

    def run(self):
        self.__renderer.render()


class RenderAppleseed(bpy.types.RenderEngine):
    bl_idname = 'APPLESEED_RENDER'
    bl_label = 'appleseed'
    bl_use_preview = True

    # This lock allows to serialize renders.
    # render_lock = threading.Lock()

    #
    # Constructor.
    #

    def __init__(self):
        logger.debug("Creating render engine")

        # Common for all rendering modes.
        self.__renderer = None
        self.__renderer_controller = None
        self.__tile_callback = None
        self.__render_thread = None

        # Interactive rendering.
        self.__interactive_scene_translator = None


    #
    # Destructor.
    #

    def __del__(self):

        self.__stop_rendering()
        logger.debug("Deleting render engine")

    #
    # RenderEngine methods.
    #

    def render(self, scene):
        if not self.is_preview:
            self.__add_render_passes(scene)

        if self.is_preview:
            if not bpy.app.background:
                self.__render_material_preview(scene)
        else:
            self.__render_final(scene)

    def update(self, data, scene):
        pass

    def view_update(self, context):
        if self.__interactive_scene_translator is None:
            self.__start_interactive_render(context)
        else:
            self.__pause_rendering()
            logger.debug("Updating scene")
            self.__interactive_scene_translator.update_scene(context.scene, context)
            self.__restart_interactive_render()

    def view_draw(self, context):
        # Check if view has changed
        view_update, camera_update = self.__interactive_scene_translator.check_view(context)

        if view_update or camera_update:
            self.__pause_rendering()
            logger.debug("Updating view")
            self.__interactive_scene_translator.update_view(view_update, camera_update)
            self.__restart_interactive_render()

        width = int(context.region.width)
        height = int(context.region.height)

        self.bind_display_space_shader(context.scene)
        self.__tile_callback.draw_pixels(0, 0, width, height)
        self.unbind_display_space_shader()

    def update_render_passes(self, scene=None, renderlayer=None):
        asr_scene_props = scene.appleseed

        if not self.is_preview:
            self.register_pass(scene, renderlayer, "Combined", 4, "RGBA", 'COLOR')
            if asr_scene_props.diffuse_aov:
                self.register_pass(scene, renderlayer, "Diffuse", 4, "RGBA", 'COLOR')
            if asr_scene_props.direct_diffuse_aov:
                self.register_pass(scene, renderlayer, "Direct Diffuse", 4, "RGBA", 'COLOR')
            if asr_scene_props.indirect_diffuse_aov:
                self.register_pass(scene, renderlayer, "Indirect Diffuse", 4, "RGBA", 'COLOR')
            if asr_scene_props.glossy_aov:
                self.register_pass(scene, renderlayer, "Glossy", 4, "RGBA", 'COLOR')
            if asr_scene_props.direct_glossy_aov:
                self.register_pass(scene, renderlayer, "Direct Glossy", 4, "RGBA", 'COLOR')
            if asr_scene_props.indirect_glossy_aov:
                self.register_pass(scene, renderlayer, "Indirect Glossy", 4, "RGBA", 'COLOR')
            if asr_scene_props.albedo_aov:
                self.register_pass(scene, renderlayer, "Albedo", 4, "RGBA", 'COLOR')
            if asr_scene_props.emission_aov:
                self.register_pass(scene, renderlayer, "Emission", 4, "RGBA", 'COLOR')
            if asr_scene_props.npr_shading_aov:
                self.register_pass(scene, renderlayer, "NPR Shading", 4, "RGBA", 'COLOR')
            if asr_scene_props.npr_contour_aov:
                self.register_pass(scene, renderlayer, "NPR Contour", 4, "RGBA", 'COLOR')
            if asr_scene_props.normal_aov:
                self.register_pass(scene, renderlayer, "Normal", 3, "RGB", 'VECTOR')
            if asr_scene_props.uv_aov:
                self.register_pass(scene, renderlayer, "UV", 3, "RGB", 'VECTOR')
            if asr_scene_props.depth_aov:
                self.register_pass(scene, renderlayer, "Z Depth", 1, "Z", 'VALUE')
            if asr_scene_props.pixel_time_aov:
                self.register_pass(scene, renderlayer, "Pixel Time", 1, "X", "VALUE")
            if asr_scene_props.invalid_samples_aov:
                self.register_pass(scene, renderlayer, "Invalid Samples", 3, "RGB", "VECTOR")
            if asr_scene_props.pixel_sample_count_aov:
                self.register_pass(scene, renderlayer, "Pixel Sample Count", 3, "RGB", "VECTOR")
            if asr_scene_props.pixel_variation_aov:
                self.register_pass(scene, renderlayer, "Pixel Variation", 3, "RGB", "VECTOR")

    #
    # Internal methods.
    #

    def __render_material_preview(self, scene):
        global _preview_renderer

        if not _preview_renderer:
            _preview_renderer = PreviewRenderer()
            _preview_renderer.translate_preview(scene)
        else:
            _preview_renderer.update_preview(scene)

        project = _preview_renderer.as_project

        self.__start_final_render(scene, project)

    def __render_final(self, scene):
        """
        Export and render the scene.
        """

        scene_translator = SceneTranslator.create_final_render_translator(scene)
        self.update_stats("appleseed Rendering: Translating scene", "")
        scene_translator.translate_scene()

        project = scene_translator.as_project

        self.__start_final_render(scene, project)

    def __start_final_render(self, scene, project):
        """
        Start a final render.
        """

        # Preconditions.
        assert(self.__renderer is None)
        assert(self.__renderer_controller is None)
        assert(self.__tile_callback is None)
        assert(self.__render_thread is None)

        self.__renderer_controller = FinalRendererController(self)

        self.__tile_callback = FinalTileCallback(self, scene)

        self.__renderer = asr.MasterRenderer(project,
                                             project.configurations()['final'].get_inherited_parameters(),
                                             self.__renderer_controller,
                                             self.__tile_callback)

        self.__render_thread = RenderThread(self.__renderer)

        # While debugging, log to the console. This should be configurable.
        log_target = asr.ConsoleLogTarget(sys.stderr)
        asr.global_logger().add_target(log_target)

        # Start render thread and wait for it to finish.
        self.__render_thread.start()

        while self.__render_thread.isAlive():
            self.__render_thread.join(0.5)  # seconds

        # Cleanup.
        asr.global_logger().remove_target(log_target)

        self.__stop_rendering()

    def __start_interactive_render(self, context):
        """
        Start an interactive rendering session.
        """

        # Preconditions.
        assert(self.__interactive_scene_translator is None)
        assert(self.__renderer is None)
        assert(self.__renderer_controller is None)
        assert(self.__tile_callback is None)
        assert(self.__render_thread is None)

        logger.debug("Translating scene for interactive rendering")

        self.__interactive_scene_translator = SceneTranslator.create_interactive_render_translator(context)
        self.__interactive_scene_translator.translate_scene()

        logger.debug("Starting interactive rendering")

        project = self.__interactive_scene_translator.as_project

        self.__renderer_controller = InteractiveRendererController()
        self.__tile_callback = asr.BlenderProgressiveTileCallback(self.tag_redraw)

        self.__renderer = asr.MasterRenderer(project,
                                             project.configurations()['interactive'].get_inherited_parameters(),
                                             self.__renderer_controller,
                                             self.__tile_callback)

        self.__restart_interactive_render()

    def __restart_interactive_render(self):
        """
        Restart the interactive renderer.
        """
        logger.debug("Start rendering")
        self.__renderer_controller.set_status(asr.IRenderControllerStatus.ContinueRendering)
        self.__render_thread = RenderThread(self.__renderer)
        self.__render_thread.start()

    def __pause_rendering(self):
        # Signal appleseed to stop rendering.
        logger.debug("Pause rendering")
        try:
            if self.__render_thread:
                self.__renderer_controller.set_status(asr.IRenderControllerStatus.AbortRendering)
                self.__render_thread.join()
        except:
            pass

        self.__render_thread = None

    def __stop_rendering(self):
        """
        Abort rendering if a render is in progress.
        """

        # Signal appleseed to stop rendering.
        logger.debug("Abort rendering")
        try:
            if self.__render_thread:
                self.__renderer_controller.set_status(asr.IRenderControllerStatus.AbortRendering)
                self.__render_thread.join()
        except:
            pass

        # Cleanup.
        self.__render_thread = None
        self.__renderer = None
        self.__renderer_controller = None
        self.__tile_callback = None

    def __add_render_passes(self, scene):
        asr_scene_props = scene.appleseed

        if asr_scene_props.diffuse_aov:
            self.add_pass("Diffuse", 4, "RGBA")
        if asr_scene_props.direct_diffuse_aov:
            self.add_pass("Direct Diffuse", 4, "RGBA")
        if asr_scene_props.indirect_diffuse_aov:
            self.add_pass("Indirect Diffuse", 4, "RGBA")
        if asr_scene_props.glossy_aov:
            self.add_pass("Glossy", 4, "RGBA")
        if asr_scene_props.direct_glossy_aov:
            self.add_pass("Direct Glossy", 4, "RGBA")
        if asr_scene_props.indirect_glossy_aov:
            self.add_pass("Indirect Glossy", 4, "RGBA")
        if asr_scene_props.normal_aov:
            self.add_pass("Normal", 3, "RGB")
        if asr_scene_props.uv_aov:
            self.add_pass("UV", 3, "RGB")
        if asr_scene_props.depth_aov:
            self.add_pass("Z Depth", 1, "Z")
        if asr_scene_props.pixel_time_aov:
            self.add_pass("Pixel Time", 1, "X")
        if asr_scene_props.invalid_samples_aov:
            self.add_pass("Invalid Samples", 3, "RGB")
        if asr_scene_props.pixel_sample_count_aov:
            self.add_pass("Pixel Sample Count", 3, "RGB")
        if asr_scene_props.pixel_variation_aov:
            self.add_pass("Pixel Variation", 3, "RGB")
        if asr_scene_props.albedo_aov:
            self.add_pass("Albedo", 4, "RGBA")
        if asr_scene_props.emission_aov:
            self.add_pass("Emission", 4, "RGBA")
        if asr_scene_props.npr_shading_aov:
            self.add_pass("NPR Shading", 4, "RGBA")
        if asr_scene_props.npr_contour_aov:
            self.add_pass("NPR Contour", 4, "RGBA")